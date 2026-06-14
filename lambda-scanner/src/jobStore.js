// jobStore.js — S3 read/write for job metadata and scan report
//
// Path conventions (CLAUDE.md §3):
//   s3://{bucket}/jobs/{jobId}/metadata.json   AZ creates with PENDING, you update the status
//   s3://{bucket}/jobs/{jobId}/report.json     you write, Bala reads
//
// Bucket name comes from an env var only — never hardcoded in source.

import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';

const BUCKET = process.env.S3_BUCKET_NAME;
const s3 = new S3Client({});

const metaKey = (jobId) => `jobs/${jobId}/metadata.json`;
const reportKey = (jobId) => `jobs/${jobId}/report.json`;

// Read metadata.json (retry logic uses retryCount); returns null if it doesn't exist.
export const getJob = async (jobId) => {
  try {
    const res = await s3.send(
      new GetObjectCommand({ Bucket: BUCKET, Key: metaKey(jobId) })
    );
    const body = await res.Body.transformToString();
    return JSON.parse(body);
  } catch (err) {
    if (err.name === 'NoSuchKey') return null;
    throw err;
  }
};

// Merge fields into existing metadata.json and write back (read-merge-write), e.g. { status: 'SUCCESS', completedAt }; returns the merged metadata.
// NOTE: read-merge-write preserves fields AZ set at creation (e.g. prNumber) — we only overwrite the keys we pass in. Don't switch to a blind PutObject or AZ's prNumber would be lost.
export const updateJob = async (jobId, fields) => {
  const current = (await getJob(jobId)) || { jobId };
  const merged = { ...current, ...fields };
  await s3.send(
    new PutObjectCommand({
      Bucket: BUCKET,
      Key: metaKey(jobId),
      Body: JSON.stringify(merged, null, 2),
      ContentType: 'application/json',
    })
  );
  return merged;
};

// Write the full scan report (CLAUDE.md §3 schema) to report.json.
export const writeReport = async (jobId, report) => {
  await s3.send(
    new PutObjectCommand({
      Bucket: BUCKET,
      Key: reportKey(jobId),
      Body: JSON.stringify(report, null, 2),
      ContentType: 'application/json',
    })
  );
};
