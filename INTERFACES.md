# CodeGuard — Integration Interfaces

This document defines the contracts between the three Lambda functions.
All teams can develop independently against these contracts.

---

## Interface A → B: SAST Scanner invocation (via SQS)

**Trigger**: Webhook Handler Lambda (Person A) sends a message to the SQS queue
`codeguard-scan-jobs` after a GitHub webhook is validated. The Scanner Lambda
(Person B) is wired to the queue with an event source mapping, so AWS delivers
each message as a normal SQS event (`event.Records[].body`).

**Queue URL**: value of environment variable `SCAN_QUEUE_URL`.

**Message body** (JSON string in `Records[].body`):
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

**What Person B must do on failure**: simply **throw** (or let the error
propagate) so the SQS message is not deleted. SQS redelivers it after the
visibility timeout, and after 3 failed receives routes it to the dead-letter
queue `codeguard-scan-dlq` — which raises a CloudWatch alarm to the SNS topic.
No custom retry event is needed.

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
  "updatedAt":   "2024-01-15T10:30:01.000Z"
}
```

**`status` lifecycle**:

| Status               | Set by   | Meaning                                           |
|----------------------|----------|---------------------------------------------------|
| `PENDING`            | Person A | Webhook received, scan job enqueued on SQS.       |
| `FAILED`             | Person A | Could not enqueue the scan job on SQS.            |
| `SUCCESS`            | Person B | Scan finished successfully. Report in S3.         |
| `FAILED`             | Person B | Scanner encountered an internal error (SQS will redeliver / DLQ). |

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

All values are set by Terraform on each Lambda (`terraform/lambda.tf`).

| Lambda | Variable | Value |
|--------|----------|-------|
| Webhook Handler | `S3_BUCKET_NAME` | `codeguard-reports-<account>` |
| Webhook Handler | `SCAN_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/<account>/codeguard-scan-jobs` |
| Webhook Handler | `AWS_REGION_NAME` | `us-east-1` |
| Webhook Handler | `WEBHOOK_SECRET_PARAM` | `/codeguard/github-webhook-secret` |
| SAST Scanner | `S3_BUCKET_NAME` | `codeguard-reports-<account>` |
| SAST Scanner | `GITHUB_TOKEN_PARAM` | `/codeguard/github-token` |
| Notifier | `S3_BUCKET_NAME` | `codeguard-reports-<account>` |
| Notifier | `SNS_TOPIC_ARN` | `arn:aws:sns:us-east-1:<account>:codeguard-alerts` |
| Notifier | `GITHUB_TOKEN_PARAM` | `/codeguard/github-token` |

---

## SNS alerts

**Topic name**: `codeguard-alerts`

**Topic ARN**: `arn:aws:sns:<region>:<account-id>:codeguard-alerts`

The `codeguard-scan-dlq-not-empty` CloudWatch alarm publishes to this topic when
a scan job lands in the dead-letter queue (failed 3 times).
Person C publishes to this topic when `summary.high > 0` in a scan report.

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
