# CodeGuard — Integration Interfaces

This document defines the contracts between the three Lambda functions.
All teams can develop independently against these contracts.

---

## Interface A → B: SAST Scanner invocation

**Trigger**: Webhook Handler Lambda (Person A) invokes Scanner Lambda (Person B)
asynchronously (`InvocationType: Event`) after a GitHub webhook is validated.

**Lambda name**: value of environment variable `SAST_LAMBDA_NAME`
(default: `codeguard-sast-scanner`).

**Invocation payload** (JSON):
```json
{
  "jobId":     "550e8400-e29b-41d4-a716-446655440000",
  "repo":      "owner/repo-name",
  "commitSha": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
}
```

| Field       | Type   | Description                                      |
|-------------|--------|--------------------------------------------------|
| `jobId`     | string | UUID v4. Use this key to read/write S3 paths.    |
| `repo`      | string | GitHub repository in `owner/repo` format.        |
| `commitSha` | string | Full 40-character commit SHA being scanned.      |

**What Person B must do on failure**: publish a `SCAN_FAILED` custom event to
the default EventBridge bus so Person A's retry rule can pick it up:

```json
{
  "Source":     "codeguard.scanner",
  "DetailType": "SCAN_FAILED",
  "Detail":     "{\"jobId\": \"<uuid>\"}"
}
```

---

## Interface A → B/C: S3 job metadata

Person A writes job metadata to S3 when a webhook arrives and updates it as
the job progresses. Person B reads `prNumber` from metadata to include in the
report. Person C reads metadata to obtain `prNumber` for posting PR comments.

**S3 path**: `s3://<S3_BUCKET_NAME>/jobs/<jobId>/metadata.json`

**Schema** (all fields always present):
```json
{
  "jobId":       "550e8400-e29b-41d4-a716-446655440000",
  "status":      "PENDING",
  "repo":        "owner/repo-name",
  "commitSha":   "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
  "branch":      "feature/my-branch",
  "prNumber":    42,
  "triggeredAt": "2024-01-15T10:30:00.000Z",
  "retryCount":  0,
  "updatedAt":   "2024-01-15T10:30:01.000Z"
}
```

**`status` lifecycle**:

| Status               | Set by   | Meaning                                           |
|----------------------|----------|---------------------------------------------------|
| `PENDING`            | Person A | Webhook received, SAST scan dispatched.           |
| `RETRYING`           | Person A | Retry attempt in progress (`retryCount` > 0).     |
| `FAILED`             | Person A | SAST Lambda invocation failed.                    |
| `PERMANENTLY_FAILED` | Person A | Retries exhausted (`retryCount` ≥ 3). SNS notified. |
| `SUCCESS`            | Person B | Scan finished successfully. Report in S3.         |
| `FAILED`             | Person B | Scanner encountered an internal error.            |

---

## Interface B → C: S3 scan report

Person B writes the scan report to S3. The S3 `ObjectCreated` event on this
path triggers the Notifier Lambda (Person C).

**S3 path**: `s3://<S3_BUCKET_NAME>/jobs/<jobId>/report.json`

**Schema**:
```json
{
  "jobId":     "550e8400-e29b-41d4-a716-446655440000",
  "repo":      "owner/repo-name",
  "commitSha": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
  "prNumber":  42,
  "scannedAt": "2024-01-15T10:30:45.000Z",
  "summary": {
    "total":  3,
    "high":   1,
    "medium": 1,
    "low":    1
  },
  "findings": [
    {
      "severity": "HIGH",
      "type":     "HARDCODED_SECRET",
      "file":     "src/config.js",
      "line":     12,
      "message":  "Hardcoded secret detected. Move secrets to environment variables."
    }
  ]
}
```

The Notifier is triggered by the S3 `ObjectCreated` event on any key matching
`jobs/*/report.json`. It reads both `report.json` and `metadata.json` (for
`prNumber`) to post the PR comment and send an SNS alert.

---

## Lambda environment variables

| Lambda | Variable | Source | Value |
|--------|----------|--------|-------|
| Webhook Handler | `S3_BUCKET_NAME` | config.env | `codeguard-reports-<account>` |
| Webhook Handler | `SAST_LAMBDA_NAME` | config.env | `codeguard-sast-scanner` |
| Webhook Handler | `AWS_REGION_NAME` | config.env | `us-east-1` |
| Webhook Handler | `WEBHOOK_SECRET_PARAM` | config.env | `/codeguard/github-webhook-secret` |
| Webhook Handler | `SNS_TOPIC_ARN` | state.env | `arn:aws:sns:us-east-1:<account>:codeguard-alerts` |
| SAST Scanner | `S3_BUCKET_NAME` | config.env | `codeguard-reports-<account>` |
| SAST Scanner | `GITHUB_TOKEN_PARAM` | config.env | `/codeguard/github-token` |
| Notifier | `S3_BUCKET_NAME` | config.env | `codeguard-reports-<account>` |
| Notifier | `SNS_TOPIC_ARN` | state.env | `arn:aws:sns:us-east-1:<account>:codeguard-alerts` |
| Notifier | `GITHUB_TOKEN_PARAM` | config.env | `/codeguard/github-token` |

---

## SNS alerts

**Topic name**: `codeguard-alerts`

**Topic ARN**: `arn:aws:sns:<region>:<account-id>:codeguard-alerts`

Person A publishes to this topic when `status = PERMANENTLY_FAILED`.
Person C publishes to this topic when `summary.high > 0` in a scan report.

**Person A — permanent failure alert** (plain text):
```json
{
  "jobId":      "<uuid>",
  "repo":       "owner/repo",
  "commitSha":  "abc123...",
  "retryCount": 3
}
```

**Person C — high severity alert** (plain text email body):
```
CodeGuard Security Scan Report

Repository: owner/repo
Total Findings: 3
High Severity:  1
Medium Severity: 1
Low Severity:   1

Most Critical Finding
...
```
