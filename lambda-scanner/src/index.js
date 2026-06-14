// Lambda entry point for the SAST Scanner.
// Handles two event types:
//   1) Normal scan: { jobId, repo, commitSha } — download → scan → write S3 → update status
//   2) Warm-up ping: event.source === 'aws.events' — return 200 immediately

import fs from 'fs';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { EventBridgeClient, PutEventsCommand } from '@aws-sdk/client-eventbridge';
import { fetchRepo } from './githubClient.js';
import { runScan } from './scanner.js';
import * as jobStore from './jobStore.js';

const ssm = new SSMClient({});
const eb = new EventBridgeClient({});

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

  const { jobId, repo, commitSha } = event || {};
  if (!jobId || !repo || !commitSha) {
    throw new Error(
      `Invalid event: expected { jobId, repo, commitSha }, got ${JSON.stringify(event)}`
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

    // Publish SCAN_FAILED event so the webhook handler's retry rule can pick it up.
    await eb
      .send(new PutEventsCommand({
        Entries: [{
          Source: 'codeguard.scanner',
          DetailType: 'SCAN_FAILED',
          Detail: JSON.stringify({ jobId }),
          EventBusName: 'default',
        }],
      }))
      .catch((e) => console.error('EventBridge SCAN_FAILED publish failed:', e.message));

    throw err;
  } finally {
    fs.rmSync(`/tmp/${jobId}`, { recursive: true, force: true });
  }
};
