'use strict';

const { S3Client, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');

const s3 = new S3Client({ region: process.env.AWS_REGION_NAME });
const BUCKET = process.env.S3_BUCKET_NAME;

function jobKey(jobId) {
  return `jobs/${jobId}/metadata.json`;
}

/**
 * Writes initial job metadata to S3.
 * @param {string} jobId
 * @param {object} data - Full metadata object to persist
 */
async function createJob(jobId, data) {
  try {
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: jobKey(jobId),
      Body: JSON.stringify(data),
      ContentType: 'application/json',
    }));
  } catch (err) {
    const error = new Error(`S3 createJob failed for jobId=${jobId}: ${err.message}`);
    error.jobId = jobId;
    error.cause = err;
    throw error;
  }
}

/**
 * Reads job metadata from S3.
 * @param {string} jobId
 * @returns {object} Parsed metadata object
 */
async function getJob(jobId) {
  try {
    const response = await s3.send(new GetObjectCommand({
      Bucket: BUCKET,
      Key: jobKey(jobId),
    }));
    const body = await response.Body.transformToString();
    return JSON.parse(body);
  } catch (err) {
    const error = new Error(`S3 getJob failed for jobId=${jobId}: ${err.message}`);
    error.jobId = jobId;
    error.cause = err;
    throw error;
  }
}

/**
 * Merges fields into existing job metadata and writes back to S3.
 * @param {string} jobId
 * @param {object} fields - Partial fields to merge (e.g. { status: 'FAILED' })
 */
async function updateJob(jobId, fields) {
  const existing = await getJob(jobId);
  const updated = { ...existing, ...fields, updatedAt: new Date().toISOString() };
  try {
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: jobKey(jobId),
      Body: JSON.stringify(updated),
      ContentType: 'application/json',
    }));
    return updated;
  } catch (err) {
    const error = new Error(`S3 updateJob failed for jobId=${jobId}: ${err.message}`);
    error.jobId = jobId;
    error.cause = err;
    throw error;
  }
}

module.exports = { createJob, getJob, updateJob };
