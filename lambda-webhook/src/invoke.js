'use strict';

const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const { updateJob } = require('./jobStore');

const sqs = new SQSClient({ region: process.env.AWS_REGION_NAME });
const SCAN_QUEUE_URL = process.env.SCAN_QUEUE_URL;

/**
 * Enqueues a scan job onto SQS. The scanner consumes the queue via an event
 * source mapping; SQS durably buffers the job and its visibility-timeout
 * redelivery + dead-letter queue handle retries (replacing the old
 * fire-and-forget Lambda invoke and the EventBridge SCAN_FAILED loop).
 *
 * On enqueue failure we mark the job FAILED in S3, then re-throw so the caller
 * can surface the error to GitHub (which will redeliver the webhook).
 *
 * @param {string} jobId
 * @param {string} repo - "owner/repo" format
 * @param {string} commitSha
 */
async function enqueueScanJob(jobId, repo, commitSha) {
  try {
    await sqs.send(new SendMessageCommand({
      QueueUrl: SCAN_QUEUE_URL,
      MessageBody: JSON.stringify({ jobId, repo, commitSha }),
    }));
  } catch (err) {
    await updateJob(jobId, {
      status: 'FAILED',
      failureReason: `Failed to enqueue scan job: ${err.message}`,
    }).catch((s3Err) => {
      console.error(JSON.stringify({
        message: 'Failed to write FAILED status to S3 after enqueue error',
        jobId,
        error: s3Err.message,
      }));
    });

    const error = new Error(`Failed to enqueue scan job for jobId=${jobId}: ${err.message}`);
    error.jobId = jobId;
    error.cause = err;
    throw error;
  }
}

module.exports = { enqueueScanJob };
