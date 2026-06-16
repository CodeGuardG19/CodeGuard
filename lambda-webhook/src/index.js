'use strict';

const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const { v4: uuidv4 } = require('uuid');
const { verifySignature } = require('./verify');
const { createJob, getJob, updateJob } = require('./jobStore');
const { invokeSastScanner } = require('./invoke');

const ssm = new SSMClient({ region: process.env.AWS_REGION_NAME });
const sns = new SNSClient({ region: process.env.AWS_REGION_NAME });

const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;
const WEBHOOK_SECRET_PARAM = process.env.WEBHOOK_SECRET_PARAM;

// Cached at cold start — avoids SSM round-trip on every invocation
let cachedWebhookSecret = null;

async function getWebhookSecret() {
  if (cachedWebhookSecret) return cachedWebhookSecret;
  const response = await ssm.send(new GetParameterCommand({
    Name: WEBHOOK_SECRET_PARAM,
    WithDecryption: true,
  }));
  cachedWebhookSecret = response.Parameter.Value;
  return cachedWebhookSecret;
}

// ── Handler ───────────────────────────────────────────────────────────────────

exports.handler = async (event) => {
  // ── 1. Warm-up ping (EventBridge scheduled rule) ───────────────────────────
  if (event.source === 'aws.events') {
    console.log(JSON.stringify({ message: 'warm-up ping received', source: event.source }));
    return { statusCode: 200, body: 'warm' };
  }

  // ── 2. Retry event (EventBridge SCAN_FAILED rule) ─────────────────────────
  if (event['detail-type'] === 'SCAN_FAILED' && event.source === 'codeguard.scanner') {
    return handleRetry(event.detail);
  }

  // ── 3. GitHub webhook (via Nginx proxy) ───────────────────────────────────
  return handleWebhook(event);
};

// ── Webhook handler ────────────────────────────────────────────────────────────

async function handleWebhook(event) {
  const signature = event.headers?.['x-hub-signature-256']
    || event.headers?.['X-Hub-Signature-256'];
  const rawBody = event.body || '';

  // Validate HMAC signature
  let secret;
  try {
    secret = await getWebhookSecret();
  } catch (err) {
    console.error(JSON.stringify({ message: 'Failed to retrieve webhook secret', error: err.message }));
    return { statusCode: 500, body: 'Internal error' };
  }

  if (!verifySignature(secret, signature, rawBody)) {
    console.warn(JSON.stringify({ message: 'Invalid webhook signature', signature: '[redacted]' }));
    return { statusCode: 401, body: 'Unauthorized' };
  }

  // GitHub ping events have no repo/commit data — acknowledge and exit early.
  const githubEvent = event.headers?.['x-github-event'] || event.headers?.['X-GitHub-Event'];
  if (githubEvent === 'ping') {
    console.log(JSON.stringify({ message: 'GitHub ping received', ok: true }));
    return { statusCode: 200, body: JSON.stringify({ message: 'pong' }) };
  }

  let payload;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return { statusCode: 400, body: 'Invalid JSON' };
  }

  const repo = payload.repository?.full_name;
  const commitSha = payload.after || payload.pull_request?.head?.sha;
  const branch = payload.ref?.replace('refs/heads/', '') || payload.pull_request?.head?.ref;

  if (!repo || !commitSha) {
    return { statusCode: 400, body: 'Missing repository or commit information' };
  }

  const prNumber = payload.pull_request?.number ?? null;

  const jobId = uuidv4();
  const metadata = {
    jobId,
    status: 'PENDING',
    repo,
    commitSha,
    branch: branch || 'unknown',
    prNumber,
    triggeredAt: new Date().toISOString(),
    retryCount: 0,
  };

  try {
    await createJob(jobId, metadata);
  } catch (err) {
    console.error(JSON.stringify({ message: 'Failed to create job in S3', jobId, error: err.message }));
    return { statusCode: 500, body: 'Failed to initialise scan job' };
  }

  // Fire-and-forget — do not await the scan result
  invokeSastScanner(jobId, repo, commitSha).catch((err) => {
    console.error(JSON.stringify({ message: 'SAST invocation error', jobId, error: err.message }));
  });

  console.log(JSON.stringify({ message: 'Webhook accepted', jobId, repo, commitSha }));

  return {
    statusCode: 202,
    body: JSON.stringify({ jobId, status: 'PENDING' }),
  };
}

// ── Retry handler ──────────────────────────────────────────────────────────────

async function handleRetry(detail) {
  const { jobId } = detail || {};
  if (!jobId) {
    console.error(JSON.stringify({ message: 'Retry event missing jobId', detail }));
    return { statusCode: 400 };
  }

  let job;
  try {
    job = await getJob(jobId);
  } catch (err) {
    console.error(JSON.stringify({ message: 'Failed to read job for retry', jobId, error: err.message }));
    return { statusCode: 500 };
  }

  if (job.retryCount >= 3) {
    console.warn(JSON.stringify({ message: 'Job reached max retries, marking PERMANENTLY_FAILED', jobId, retryCount: job.retryCount }));
    await updateJob(jobId, { status: 'PERMANENTLY_FAILED' }).catch((e) =>
      console.error(JSON.stringify({ message: 'Failed to update job to PERMANENTLY_FAILED', jobId, error: e.message }))
    );

    if (SNS_TOPIC_ARN) {
      await sns.send(new PublishCommand({
        TopicArn: SNS_TOPIC_ARN,
        Subject: `CodeGuard: Scan permanently failed for ${job.repo}`,
        Message: JSON.stringify({ jobId, repo: job.repo, commitSha: job.commitSha, retryCount: job.retryCount }),
      })).catch((e) =>
        console.error(JSON.stringify({ message: 'SNS publish failed', jobId, error: e.message }))
      );
    }
    return { statusCode: 200 };
  }

  const newRetryCount = job.retryCount + 1;
  await updateJob(jobId, { status: 'RETRYING', retryCount: newRetryCount });
  console.log(JSON.stringify({ message: 'Retrying scan', jobId, retryCount: newRetryCount }));

  await invokeSastScanner(jobId, job.repo, job.commitSha);

  return { statusCode: 200 };
}
