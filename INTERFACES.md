# CodeGuard — Integration Interfaces

This document defines the contracts between Person A's webhook handler and
Person B (SAST Scanner) and Person C (S3/SNS/PR Comment). Both teams can
develop independently against these contracts.

---

## Interface A → B: SAST Scanner invocation

**Trigger**: Person A's Lambda webhook handler invokes Person B's Lambda
asynchronously (`InvocationType: Event`) after a GitHub webhook is validated.

**Lambda name**: value of environment variable `SAST_LAMBDA_NAME`
(default: `codeguard-sast-scanner`).

**Invocation payload** (JSON):
```json
{
  "jobId":    "550e8400-e29b-41d4-a716-446655440000",
  "repo":     "owner/repo-name",
  "commitSha":"a1b2c3d4e5f6..."
}
```

| Field       | Type   | Description                                      |
|-------------|--------|--------------------------------------------------|
| `jobId`     | string | UUID v4. Use this to write scan results to S3.   |
| `repo`      | string | GitHub repository in `owner/repo` format.        |
| `commitSha` | string | Full 40-character commit SHA being scanned.      |

**What Person B must do on failure**: publish a custom EventBridge event to
the default event bus so Person A's retry logic can pick it up:

```json
{
  "Source":      "codeguard.scanner",
  "DetailType":  "SCAN_FAILED",
  "Detail": "{\"jobId\": \"<uuid>\"}"
}
```

---

## Interface A → C: S3 job metadata

Person A writes job metadata to S3 when a webhook is received and updates it
as the job progresses. Person C reads this to post PR comments and send alerts.

**S3 path**: `s3://<S3_BUCKET_NAME>/jobs/<jobId>/metadata.json`

**Schema** (all fields always present):
```json
{
  "jobId":        "550e8400-e29b-41d4-a716-446655440000",
  "status":       "PENDING",
  "repo":         "owner/repo-name",
  "commitSha":    "a1b2c3d4e5f6...",
  "branch":       "main",
  "triggeredAt":  "2024-01-15T10:30:00.000Z",
  "retryCount":   0,
  "updatedAt":    "2024-01-15T10:30:01.000Z"
}
```

**`status` lifecycle**:

| Status               | Set by   | Meaning                                           |
|----------------------|----------|---------------------------------------------------|
| `PENDING`            | Person A | Webhook received, SAST scan dispatched.           |
| `RETRYING`           | Person A | Retry attempt in progress (`retryCount` > 0).     |
| `FAILED`             | Person A | SAST Lambda invocation failed.                    |
| `PERMANENTLY_FAILED` | Person A | Retries exhausted (retryCount ≥ 3). SNS notified. |
| `SCANNING`           | Person B | Scanner Lambda has started processing.            |
| `COMPLETE`           | Person B | Scan finished successfully. Results in S3.        |
| `SCAN_ERROR`         | Person B | Scanner encountered an internal error.            |

Person B should write scan results to:
`s3://<S3_BUCKET_NAME>/jobs/<jobId>/results.json`

Person C should watch for `COMPLETE` and `PERMANENTLY_FAILED` statuses to
trigger PR comments and SNS alerts respectively.

---

## SNS alerts

**Topic name**: `codeguard-scan-alerts`

**Topic ARN**: `arn:aws:sns:<region>:<account-id>:codeguard-scan-alerts`

Person A publishes to this topic when `status = PERMANENTLY_FAILED`.
Person C subscribes to this topic for all scan result notifications.

Message format:
```json
{
  "jobId":      "<uuid>",
  "repo":       "owner/repo",
  "commitSha":  "abc123...",
  "retryCount": 3
}
```
