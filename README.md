# CodeGuard — Automated GitHub Security Scanner

CodeGuard is a cloud-native SAST (Static Application Security Testing) pipeline that scans pull requests for security vulnerabilities and posts results as PR comments. It is fully serverless on AWS and deployable with a single script.

---

## Quick Start

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI v2 | ≥ 2.x | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| Docker | ≥ 24.x | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Node.js | ≥ 18.x | [nodejs.org](https://nodejs.org/) |
| git | any | — |

### Step 1 — Clone the repository

```bash
git clone https://github.com/<your-org>/CodeGuard.git
cd CodeGuard
git checkout main
```

### Step 2 — Configure your AWS credentials

Use AWS Academy / Learner Lab credentials, or any account with AdministratorAccess:

```bash
aws configure          # enter Access Key ID, Secret, region = us-east-1
# OR export the env vars directly from the Learner Lab "AWS Details" panel
```

### Step 3 — Edit `infra/config.env`

Open `infra/config.env` and set **two values**:

```bash
export AWS_ACCOUNT_ID="123456789012"          # your 12-digit AWS account number
export NOTIFICATION_EMAIL="you@example.com"   # receives SNS security alerts
```

Everything else is pre-configured with sensible defaults.

### Step 4 — Create SSM secrets (run once)

CodeGuard reads two secrets from AWS Systems Manager Parameter Store at runtime — they are never stored in code or environment variables.

```bash
# GitHub Webhook Secret — any random string you choose (set the same value in GitHub)
aws ssm put-parameter \
  --name "/codeguard/github-webhook-secret" \
  --value "YOUR_WEBHOOK_SECRET" \
  --type SecureString --region us-east-1

# GitHub Personal Access Token — needs repo scope (for PR comments + code download)
aws ssm put-parameter \
  --name "/codeguard/github-token" \
  --value "ghp_YOUR_TOKEN_HERE" \
  --type SecureString --region us-east-1
```

### Step 5 — Deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

The script takes 10–15 minutes. It prints a summary at the end:

```
╔═══════════════════════════════════════════════════════════╗
║  Public webhook URL: https://<EC2-IP>/webhook             ║
╚═══════════════════════════════════════════════════════════╝
```

### Step 6 — Configure GitHub webhook

In the target GitHub repository:

1. Go to **Settings → Webhooks → Add webhook**
2. Set **Payload URL** to `https://<EC2-IP>/webhook`
3. Set **Content type** to `application/json`
4. Set **Secret** to the value from Step 4
5. Select events: **Pull requests** and **Pushes**
6. Click **Add webhook**

### Step 7 — Confirm SNS subscription

Check `NOTIFICATION_EMAIL` inbox and click **Confirm subscription** in the AWS email.

### Teardown

```bash
./teardown.sh             # removes all resources, preserves S3 reports
./teardown.sh --delete-s3 # also empties and deletes the S3 bucket
```

---

## Architecture

```
GitHub Repo
(push / pull_request event)
        │
        ▼
   EC2 Nginx Proxy
   (HTTPS, rate limiting)
        │
        ▼
Lambda — Webhook Handler       ← Person A (Aqeel)
(HMAC signature verification,
 job creation in S3)
        │  async invoke
        ▼
Lambda — SAST Scanner          ← Person B (Ke Xu)
(downloads repo from GitHub,
 runs security rule engine,
 writes JSON report to S3)
        │
        ▼  S3 ObjectCreated trigger
Lambda — Notifier              ← Person C (Bala)
(reads report + metadata,
 posts GitHub PR comment,
 sends SNS email if HIGH severity)
       ╱ ╲
      ▼    ▼
  SNS     GitHub API
(email)  (PR comment)
```

### Data Flow

1. Developer opens a PR → GitHub fires a `POST` to the Nginx webhook endpoint
2. **Webhook Handler** verifies the HMAC-SHA256 signature, creates a `PENDING` job in S3 (`jobs/{jobId}/metadata.json`), and async-invokes the Scanner
3. **SAST Scanner** downloads the repo tarball from GitHub, runs the rule engine, saves `jobs/{jobId}/report.json` to S3, and updates metadata to `SUCCESS`
4. The S3 `ObjectCreated` event fires the **Notifier**
5. **Notifier** reads the report: if HIGH-severity findings exist, sends SNS email; posts a summary comment on the PR

### Retry Logic

If the Scanner fails, it publishes a `SCAN_FAILED` EventBridge event. The Webhook Handler retries up to 3 times. On permanent failure it publishes an SNS alert.

---

## Repository Structure

```
CodeGuard/
├── deploy.sh                   # Master deployment script (run this)
├── teardown.sh                 # Tear down all infrastructure
├── infra/
│   ├── config.env              # ← Edit AWS_ACCOUNT_ID and NOTIFICATION_EMAIL here
│   ├── state.env               # Auto-generated resource IDs (do not edit)
│   ├── 01-vpc.sh               # VPC, subnets, IGW, NAT Gateway, VPC endpoints
│   ├── 02-security.sh          # Security groups (EC2, Lambda)
│   ├── 03-ec2.sh               # EC2 Nginx proxy
│   ├── 04-lambda.sh            # Webhook Handler Lambda (ECR image)
│   ├── 05-cloudwatch.sh        # CloudWatch log groups and alarms
│   ├── 06-s3-sns.sh            # Shared S3 bucket + SNS topic
│   ├── 07-lambda-scanner.sh    # SAST Scanner Lambda (ECR image)
│   └── 08-lambda-notifier.sh   # Notifier Lambda (zip) + S3 trigger
├── lambda-webhook/             # Person A — webhook handler source
│   ├── Dockerfile
│   └── src/
│       ├── index.js            # Handler: HMAC verify → create job → invoke scanner
│       ├── verify.js           # HMAC-SHA256 signature verification
│       ├── jobStore.js         # S3 read/write for job metadata
│       └── invoke.js           # Async Lambda-to-Lambda invocation
├── lambda-scanner/             # Person B — SAST scanner source
│   ├── Dockerfile
│   ├── sast-engine/
│   │   └── scanner.js          # Security rule engine (regex-based, 10 rule categories)
│   └── src/
│       ├── index.js            # Handler: download → scan → write report → EventBridge
│       ├── scanner.js          # Engine wrapper (normalises output to report schema)
│       ├── jobStore.js         # S3 read/write for metadata and report
│       └── githubClient.js     # GitHub tarball download + extraction
└── lambda-notifier/            # Person C — notifier source
    ├── package.json
    └── index.mjs               # Handler: read S3 → SNS alert → GitHub PR comment
```

---

## SAST Rule Categories

The scanner detects the following vulnerability types in JavaScript/TypeScript:

| Severity | Rule | Description |
|----------|------|-------------|
| HIGH | `HARDCODED_SECRET` | API keys, passwords, AWS keys, GitHub tokens in source |
| HIGH | `SQL_INJECTION` | String concatenation / template literals in SQL queries |
| HIGH | `NOSQL_INJECTION` | Unsanitised user input in MongoDB queries |
| HIGH | `XSS` | `innerHTML`, `document.write`, `dangerouslySetInnerHTML` |
| HIGH | `PATH_TRAVERSAL` | User input in `fs` calls or `path.join` |
| HIGH | `INSECURE_FUNCTION` | `eval()`, `exec()`, `new Function()` |
| MEDIUM | `INSECURE_RANDOM` | `Math.random()` used for security-sensitive values |
| MEDIUM | `SENSITIVE_DATA_LOG` | Passwords/tokens passed to `console.log` |
| MEDIUM | `HARDCODED_IP` | IP addresses hardcoded in source |
| MEDIUM | `WEAK_CRYPTO` | MD5, SHA1, deprecated `createCipher` |
| LOW | `SECURITY_TODO` | Security-related TODO/FIXME/HACK comments |

---

## Infrastructure Overview

| Resource | Name | Purpose |
|----------|------|---------|
| EC2 (t3.micro) | `codeguard-ec2` | Nginx HTTPS proxy, rate limiting, HMAC forwarding |
| Lambda | `codeguard-webhook-handler` | Validates webhook, creates job, invokes scanner |
| Lambda | `codeguard-sast-scanner` | Downloads repo, runs SAST, writes report |
| Lambda | `codeguard-notifier` | Posts PR comment, sends SNS alert |
| S3 | `codeguard-reports-{account}` | Stores job metadata and scan reports |
| SNS | `codeguard-alerts` | Email alerts for HIGH-severity findings |
| ECR | `codeguard-webhook-handler` | Docker image for webhook Lambda |
| ECR | `codeguard-sast-scanner` | Docker image for scanner Lambda |
| SSM | `/codeguard/github-webhook-secret` | Webhook HMAC secret |
| SSM | `/codeguard/github-token` | GitHub PAT for downloads + PR comments |

All Lambdas run in a private VPC subnet with a NAT Gateway for outbound internet access. S3 and SNS are accessed via VPC endpoints.

---

## S3 Data Schema

**`jobs/{jobId}/metadata.json`** — created by Webhook Handler, updated by Scanner:

```json
{
  "jobId": "uuid",
  "status": "PENDING | SUCCESS | FAILED | RETRYING | PERMANENTLY_FAILED",
  "repo": "owner/repo-name",
  "commitSha": "40-char SHA",
  "branch": "main",
  "prNumber": 42,
  "triggeredAt": "ISO-8601",
  "retryCount": 0
}
```

**`jobs/{jobId}/report.json`** — written by Scanner, read by Notifier:

```json
{
  "jobId": "uuid",
  "repo": "owner/repo-name",
  "commitSha": "40-char SHA",
  "prNumber": 42,
  "scannedAt": "ISO-8601",
  "summary": { "total": 3, "high": 1, "medium": 1, "low": 1 },
  "findings": [
    {
      "severity": "HIGH",
      "type": "hardcoded-secret",
      "file": "src/config.js",
      "line": 12,
      "message": "Hardcoded secret detected. Move secrets to environment variables."
    }
  ]
}
```

---

## Team

| Member | Scope |
|--------|-------|
| Person A (Aqeel) | API Gateway · EC2 Nginx · Webhook Handler Lambda · HMAC verification · VPC networking |
| Person B (Ke Xu) | SAST Scanner Lambda · ECR · Docker · GitHub code download · SAST rule engine |
| Person C (Bala) | Notifier Lambda · SNS alerts · GitHub PR comments · S3 event trigger |
