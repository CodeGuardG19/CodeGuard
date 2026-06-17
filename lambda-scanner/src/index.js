// Lambda entry point for the SAST Scanner.
// Handles two event types:
//   1) Scan job from SQS: Records[].body = { jobId, repo, commitSha }
//      — download → scan → write S3 → update status. A thrown error lets SQS
//        redeliver the message (visibility timeout) and, after maxReceiveCount,
//        route it to the dead-letter queue.
//   2) Warm-up ping: event.source === 'aws.events' — return 200 immediately

import fs from 'fs';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { fetchRepo } from './githubClient.js';
import { runScan } from './scanner.js';
import * as jobStore from './jobStore.js';

const ssm = new SSMClient({});

// Cache the GitHub token across warm invocations — fetched once from SSM.
let tokenPromise;
const getGithubToken = () => {
  if (!tokenPromise) {
    tokenPromise = ssm
      .send(new GetParameterCommand({
        Name: process.env.GITHUB_TOKEN_PARAM || '/codeguard/github-token',
        WithDecryption: true,
      }))
      .then((r) => r.Parameter.Value)
      .catch((err) => {
        tokenPromise = undefined;
        throw err;
      });
  }
  return tokenPromise;
};

export const handler = async (event) => {
  // Warm-up ping from EventBridge scheduled rule
  if (event && event.source === 'aws.events') {
    console.log('warm-up ping received');
    return { statusCode: 200, body: 'warm' };
  }

  // Scan jobs arrive from SQS. batch_size = 1, but iterate defensively; a thrown
  // error fails the message so SQS redelivers it (and eventually DLQs it).
  if (!event?.Records?.length) {
    throw new Error(`Invalid event: expected SQS Records, got ${JSON.stringify(event)}`);
  }

  for (const record of event.Records) {
    let job;
    try {
      job = JSON.parse(record.body);
    } catch {
      throw new Error(`Invalid SQS message body: ${record.body}`);
    }
    await processScan(job);
  }

  return { statusCode: 200 };
};

async function processScan(event) {
  const { jobId, repo, commitSha } = event || {};
  if (!jobId || !repo || !commitSha) {
    throw new Error(
      `Invalid scan job: expected { jobId, repo, commitSha }, got ${JSON.stringify(event)}`
    );
  }

  console.log(`Scan start: jobId=${jobId} repo=${repo} sha=${commitSha}`);

  try {
    let token;
    try {
      token = await getGithubToken();
    } catch (e) {
      console.warn(`No GitHub token from SSM (${e.message}) — proceeding unauthenticated`);
    }

    const localPath = await fetchRepo(repo, commitSha, jobId, token);
    const { summary, findings } = runScan(localPath);

    // Carry prNumber from metadata into the report so the notifier can post the PR comment.
    const meta = await jobStore.getJob(jobId);
    const prNumber = meta?.prNumber ?? null;

    const report = {
      jobId,
      repo,
      commitSha,
      prNumber,
      scannedAt: new Date().toISOString(),
      summary,
      findings,
    };

    await jobStore.writeReport(jobId, report);
    await jobStore.updateJob(jobId, {
      status: 'SUCCESS',
      completedAt: new Date().toISOString(),
      errorReason: null,
    });

    console.log(`Scan done: jobId=${jobId} findings=${summary.total}`);
    return { statusCode: 200, jobId, summary };

  } catch (err) {
    console.error(`Scan failed: jobId=${jobId}`, err);

    await jobStore
      .updateJob(jobId, {
        status: 'FAILED',
        errorReason: err.message,
        completedAt: new Date().toISOString(),
      })
      .catch((e) => console.error('updateJob(FAILED) also failed:', e));

    // Re-throw so the SQS message is not deleted: SQS redelivers it after the
    // visibility timeout and routes it to the DLQ after maxReceiveCount.
    throw err;
  } finally {
    fs.rmSync(`/tmp/${jobId}`, { recursive: true, force: true });
  }
}
