'use strict';

const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');
const { updateJob } = require('./jobStore');

const lambda = new LambdaClient({ region: process.env.AWS_REGION_NAME });
const SAST_LAMBDA_NAME = process.env.SAST_LAMBDA_NAME;

/**
 * Asynchronously invokes Person B's SAST Scanner Lambda.
 *
 * InvocationType=Event means fire-and-forget — we do not wait for the scan
 * to complete. Lambda's built-in async retry (MaximumRetryAttempts=2) handles
 * transient failures; EventBridge handles structured retry on SCAN_FAILED events.
 *
 * On invocation failure we mark the job FAILED in S3 so EventBridge can pick
 * it up, then re-throw so the Lambda runtime records the error.
 *
 * @param {string} jobId
 * @param {string} repo - "owner/repo" format
 * @param {string} commitSha
 */
async function invokeSastScanner(jobId, repo, commitSha) {
  const payload = JSON.stringify({ jobId, repo, commitSha });

  try {
    await lambda.send(new InvokeCommand({
      FunctionName: SAST_LAMBDA_NAME,
      InvocationType: 'Event',
      Payload: Buffer.from(payload),
    }));
  } catch (err) {
    await updateJob(jobId, {
      status: 'FAILED',
      failureReason: `SAST Scanner invocation failed: ${err.message}`,
    }).catch((s3Err) => {
      console.error(JSON.stringify({
        message: 'Failed to write FAILED status to S3 after invocation error',
        jobId,
        error: s3Err.message,
      }));
    });

    const error = new Error(`SAST Scanner invocation failed for jobId=${jobId}: ${err.message}`);
    error.jobId = jobId;
    error.cause = err;
    throw error;
  }
}

module.exports = { invokeSastScanner };
