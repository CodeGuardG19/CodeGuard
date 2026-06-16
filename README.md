# CodeGuard — Automated GitHub Security Scanner

CodeGuard is a cloud-native SAST (Static Application Security Testing) pipeline that scans pull requests for security vulnerabilities and posts results as PR comments. It is fully serverless on AWS and deployable with a single script.

---

## Quick Start

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI v2 | ≥ 2.1 (`apigatewayv2` support) | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| Docker | ≥ 24.x | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Node.js | ≥ 18.x | [nodejs.org](https://nodejs.org/) |
| git | any | — |

> **AWS Academy Lab users:** ingress is an **API Gateway HTTP API**, not a Lambda
> Function URL. The Academy SCP **blocks anonymous Function URL invocation**
> (`AuthType=NONE` requests are rejected with `403 Forbidden` at the AWS platform
> layer, before reaching your code), so a Function URL is not usable in the Lab.
> API Gateway invokes the Lambda via the `apigateway.amazonaws.com` principal, so
> it is not affected by that SCP. The `apigatewayv2` commands ship in the Lab's
> default CLI (`2.1.11`), so **no CLI upgrade is required**.

### Step 1 — Clone the repository

```bash
git clone https://github.com/CodeGuardG19/CodeGuard.git
cd CodeGuard
git branch <YOUR_NEW_BRANCH>
git checkout <YOUR_NEW_BRANCH>
```

### Step 2 — Configure your AWS credentials

Use AWS Academy / Learner Lab credentials, or any account with AdministratorAccess:

```bash
aws configure          # enter Access Key ID, Secret, region = us-east-1
# OR export the env vars directly from the Learner Lab "AWS Details" panel
```

### Step 3 — Edit `infra/config.env` (Run everytime a new session is started)

Open `infra/config.env` and set **two values**:

```bash
export AWS_ACCOUNT_ID="123456789012"          # your 12-digit AWS account number
export NOTIFICATION_EMAIL="you@example.com"   # receives SNS security alerts
```

Everything else is pre-configured with sensible defaults.

### Step 4 — Create SSM secrets (run once)

CodeGuard reads two secrets from AWS Systems Manager Parameter Store at runtime — they are never stored in code or environment variables.

```bash
# Use random strings for both of these, you can create one by running this command:
openssl rand -hex 32

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

Make sure Docker Desktop is up and running. Then:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script takes 10–15 minutes. It prints a summary at the end:

```
  Public webhook URL (API Gateway HTTP API):
    https://<id>.execute-api.us-east-1.amazonaws.com/webhook
```

### Step 6 — Configure GitHub webhook

In the target GitHub repository, where you want this SAST scanner to run:

1. Go to **Settings → Webhooks → Add webhook**
2. Set **Payload URL** to the API Gateway URL printed by `deploy.sh` (HTTPS, e.g. `https://<id>.execute-api.us-east-1.amazonaws.com/webhook`)
3. Set **Content type** to `application/json`
4. Set **Secret** to the value you put in SSM in Step 4
5. Under **Which events**, select **Let me select individual events** → check **Pull requests**
6. Click **Add webhook**

GitHub will immediately send a ping event. The webhook should show a green checkmark and a `202 Accepted` response. If it shows a red ✗, check that the API Gateway URL is correct (it must end in `/webhook`) and the webhook secret matches the SSM value.

### Step 7 — Confirm SNS subscription

Check `NOTIFICATION_EMAIL` inbox and click **Confirm subscription** in the AWS email before testing — alerts will not be delivered until the subscription is confirmed. Check your spam folder if it does not arrive within a minute.

### Step 8 — Trigger a scan with a pull request

**1. Add a file with a detectable vulnerability to a new branch:**

```bash
# In a local clone of the target repo
git checkout -b test/security-scan

cat > test-vulnerable.js << 'EOF'
// Intentional vulnerabilities for CodeGuard demo
const password = "supersecret123";          // HARDCODED_SECRET
const query = "SELECT * FROM users WHERE id = " + userId;  // SQL_INJECTION
eval(userInput);                            // INSECURE_FUNCTION
EOF

git add test-vulnerable.js
git commit -m "test: add file to trigger CodeGuard scan"
git push origin test/security-scan
```

**2. Open a pull request** on GitHub: `test/security-scan` → `main`

**3. What happens next (automatically):**

| Time | Event |
|------|-------|
| 0 s | GitHub fires a `pull_request` webhook to the API Gateway endpoint |
| ~1 s | API Gateway invokes the Webhook Handler Lambda; GitHub receives `202 Accepted` |
| ~2 s | Webhook Handler verifies HMAC, creates a job record in S3, invokes the SAST Scanner |
| ~30–60 s | SAST Scanner downloads the repo, runs the rule engine, writes the report to S3 |
| ~60–90 s | Notifier Lambda reads the report, posts a comment on the PR, sends an SNS email if HIGH severity findings exist |

**4. Check results:**

- **PR comment** — the Notifier posts a findings summary directly on the pull request
- **Email** — if any HIGH-severity vulnerabilities were found, an alert arrives at `NOTIFICATION_EMAIL`
- **S3 report** — the full JSON report is at:

```bash
# List all scan jobs
aws s3 ls s3://codeguard-reports-<ACCOUNT_ID>/jobs/ --region us-east-1

# Download a specific report (replace JOB_ID with the ID from the PR comment)
aws s3 cp s3://codeguard-reports-<ACCOUNT_ID>/jobs/<JOB_ID>/report.json /tmp/report.json --region us-east-1
cat /tmp/report.json
```

### Teardown

```bash
bash infra/teardown.sh    # removes all resources, preserves S3 reports
bash infra/teardown.sh --delete-s3	# also deletes S3 reports
```

---

## Architecture

```
GitHub Repo
(push / pull_request event)
        │
        ▼
 API Gateway (HTTP API)
 (public HTTPS, POST /webhook)
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

1. Developer opens a PR → GitHub fires a `POST` to the public API Gateway endpoint (`POST /webhook`)
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
├── infra/
│   ├── config.env              # ← Edit AWS_ACCOUNT_ID and NOTIFICATION_EMAIL here
│   ├── state.env               # Auto-generated resource IDs (do not edit)
│   ├── 01-vpc.sh               # VPC, subnets, IGW, NAT Gateway, VPC endpoints
│   ├── 02-security.sh          # Security group (Lambda)
│   ├── 04-lambda.sh            # Webhook Handler Lambda (ECR image) + API Gateway HTTP API
│   ├── 05-cloudwatch.sh        # CloudWatch log groups and alarms
│   ├── 06-s3-sns.sh            # Shared S3 bucket + SNS topic
│   ├── 07-lambda-scanner.sh    # SAST Scanner Lambda (ECR image)
│   ├── 08-lambda-notifier.sh   # Notifier Lambda (zip) + S3 trigger
│   └── teardown.sh             # Tear down all infrastructure
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
| API Gateway (HTTP API) | `codeguard-webhook-api` | Public HTTPS ingress (`POST /webhook`) — the GitHub webhook target |
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
| Person A (Aqeel) | API Gateway (HTTP API) · Webhook Handler Lambda · HMAC verification · VPC networking |
| Person B (Ke Xu) | SAST Scanner Lambda · ECR · Docker · GitHub code download · SAST rule engine |
| Person C (Bala) | Notifier Lambda · SNS alerts · GitHub PR comments · S3 event trigger |
