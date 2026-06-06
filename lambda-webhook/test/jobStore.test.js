'use strict';

// Mock AWS SDK v3 S3 client before requiring jobStore
jest.mock('@aws-sdk/client-s3', () => {
  const mockSend = jest.fn();
  return {
    S3Client: jest.fn().mockImplementation(() => ({ send: mockSend })),
    GetObjectCommand: jest.fn().mockImplementation((params) => ({ _params: params, _type: 'Get' })),
    PutObjectCommand: jest.fn().mockImplementation((params) => ({ _params: params, _type: 'Put' })),
    __mockSend: mockSend,
  };
});

const { __mockSend } = require('@aws-sdk/client-s3');
const { createJob, getJob, updateJob } = require('../src/jobStore');

const JOB_ID = 'test-job-uuid-1234';
const SAMPLE_JOB = {
  jobId: JOB_ID,
  status: 'PENDING',
  repo: 'owner/repo',
  commitSha: 'abc123',
  branch: 'main',
  triggeredAt: '2024-01-01T00:00:00.000Z',
  retryCount: 0,
};

beforeEach(() => {
  jest.clearAllMocks();
  process.env.S3_BUCKET_NAME = 'test-bucket';
  process.env.AWS_REGION_NAME = 'us-east-1';
});

describe('createJob', () => {
  test('calls PutObject with correct key and JSON body', async () => {
    __mockSend.mockResolvedValueOnce({});
    await createJob(JOB_ID, SAMPLE_JOB);

    const call = __mockSend.mock.calls[0][0];
    expect(call._type).toBe('Put');
    expect(call._params.Key).toBe(`jobs/${JOB_ID}/metadata.json`);
    expect(call._params.ContentType).toBe('application/json');
    expect(JSON.parse(call._params.Body)).toMatchObject(SAMPLE_JOB);
  });

  test('throws structured error with jobId on S3 failure', async () => {
    __mockSend.mockRejectedValueOnce(new Error('Network error'));
    await expect(createJob(JOB_ID, SAMPLE_JOB)).rejects.toMatchObject({
      message: expect.stringContaining(JOB_ID),
      jobId: JOB_ID,
    });
  });
});

describe('getJob', () => {
  test('reads and parses job metadata from S3', async () => {
    const mockBody = {
      transformToString: async () => JSON.stringify(SAMPLE_JOB),
    };
    __mockSend.mockResolvedValueOnce({ Body: mockBody });

    const result = await getJob(JOB_ID);
    expect(result).toMatchObject(SAMPLE_JOB);

    const call = __mockSend.mock.calls[0][0];
    expect(call._type).toBe('Get');
    expect(call._params.Key).toBe(`jobs/${JOB_ID}/metadata.json`);
  });

  test('throws structured error with jobId on S3 failure', async () => {
    __mockSend.mockRejectedValueOnce(new Error('NoSuchKey'));
    await expect(getJob(JOB_ID)).rejects.toMatchObject({
      message: expect.stringContaining(JOB_ID),
      jobId: JOB_ID,
    });
  });
});

describe('updateJob', () => {
  test('merges fields and writes back', async () => {
    const mockBody = {
      transformToString: async () => JSON.stringify(SAMPLE_JOB),
    };
    __mockSend
      .mockResolvedValueOnce({ Body: mockBody }) // getJob
      .mockResolvedValueOnce({});                 // PutObject

    const updated = await updateJob(JOB_ID, { status: 'FAILED', retryCount: 1 });

    expect(updated.status).toBe('FAILED');
    expect(updated.retryCount).toBe(1);
    expect(updated.repo).toBe(SAMPLE_JOB.repo);
    expect(updated.updatedAt).toBeDefined();

    const putCall = __mockSend.mock.calls[1][0];
    expect(putCall._type).toBe('Put');
    const written = JSON.parse(putCall._params.Body);
    expect(written.status).toBe('FAILED');
  });

  test('throws on write failure after successful read', async () => {
    const mockBody = {
      transformToString: async () => JSON.stringify(SAMPLE_JOB),
    };
    __mockSend
      .mockResolvedValueOnce({ Body: mockBody })
      .mockRejectedValueOnce(new Error('Write error'));

    await expect(updateJob(JOB_ID, { status: 'FAILED' })).rejects.toMatchObject({
      message: expect.stringContaining(JOB_ID),
      jobId: JOB_ID,
    });
  });
});
