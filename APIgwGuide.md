# CodeGuard Ingress Change: From EC2 / Function URL to API Gateway

> This document records the full decision path for CodeGuard's webhook ingress:
> **why an EC2-fronted Lambda was rejected, why a Lambda Function URL does not work
> inside the AWS Academy Lab, and why we ultimately switched to an API Gateway HTTP API.**
> It also covers exactly which files changed, the end-to-end trigger flow, and real log
> samples. Every conclusion below was verified by direct testing.

---

## 1. Background: Why the Ingress Had to Change

CodeGuard is a fully serverless SAST pipeline. Its ingress must satisfy one hard constraint:

> **GitHub must be able to POST the webhook straight in from the public internet**, and
> GitHub cannot AWS-SigV4-sign its requests — so the ingress must accept *anonymous*
> (no AWS credentials) HTTPS requests. Authentication is done at the application layer
> via HMAC-SHA256.

### 1.1 Why not EC2 in front of Lambda (rejected option)

We initially considered "a long-running service on EC2 receives the webhook and then
invokes Lambda," but this conflicts with the project's goals:

| Problem | Detail |
|---------|--------|
| **Defeats the serverless goal** | The whole project is about "fully serverless, pay-per-use, zero ops." A long-running EC2 box means another server to patch, monitor, and pay for 24×7. |
| **Cost & idle waste** | Webhooks are low-frequency, bursty traffic. Keeping an EC2 instance running for them is wasteful; Lambda is the natural fit. |
| **Extra failure point / attack surface** | EC2 needs open inbound ports, TLS cert maintenance, and a reverse proxy — added operational and security burden. |
| **Poor elasticity** | EC2 has to handle concurrency and scaling itself; Lambda + a managed ingress scales automatically. |

**Conclusion: the ingress should be a managed, serverless HTTPS endpoint that hands the
request directly to Lambda.** That led to the two candidate options tested below.

---

## 2. Attempt 1: Lambda Function URL (creates fine, but cannot be invoked)

A Lambda Function URL is the lightest option — attach a public HTTPS address directly to
the Lambda, with no layer in between.

### 2.1 Anonymous access (AuthType = NONE): creates ✅ but invocation blocked ❌

Following the "public endpoint + application-layer HMAC verification" design, we first
created a `AuthType=NONE` Function URL:

```bash
aws lambda create-function-url-config \
  --function-name codeguard-webhook-handler \
  --auth-type NONE \
  --region us-east-1
```

- **Creation itself succeeds**: the command returns normally and the URL is generated.
- **But anonymous invocation is rejected outright**: any request without AWS credentials
  (exactly what GitHub sends) returns **`403 Forbidden`**.

The key point: **this is blocked at the AWS platform layer (an SCP) — the request never
reaches the Lambda code.** The AWS Academy Lab's Service Control Policy (SCP) contains a rule:

> **No one may invoke a Function URL anonymously** (i.e. `AuthType=NONE` is not permitted).

In a normal AWS account `NONE` is allowed (open is open), but the Academy Lab management
policy adds this extra rule; the `LabRole` / account policy does not allow a Function URL to
be exposed anonymously to the public. Our test hit exactly this rule — the anonymous request
was stopped at the door.

### 2.2 Signed access (AuthType = AWS_IAM): invokes fine ✅ (but unusable for GitHub)

To confirm "the Function URL itself isn't broken — only anonymous is forbidden," we ran a
control experiment with `AuthType=AWS_IAM`:

- Switched the Function URL to `AWS_IAM`, then called it with a **SigV4-signed** request
  (carrying Lab credentials).
- **Result: the call succeeded and the request reached the Lambda normally.**

This precisely proves the nature of the problem:

> **The Function URL "channel" works; what's disabled is only the "anonymous (NONE)"
> auth mode.** A signed request gets in, but **GitHub cannot AWS-SigV4-sign a webhook**, so
> `AWS_IAM` is useless for our scenario (even though we ourselves can call it when signed).

### 2.3 Summary: Function URL is a dead end in the Lab

| Mode | Creatable? | Callable by GitHub? | Reason |
|------|-----------|---------------------|--------|
| `AuthType=NONE` | ✅ | ❌ 403 (platform-layer block) | Academy SCP forbids anonymous Function URL invocation |
| `AuthType=AWS_IAM` | ✅ | ❌ | GitHub cannot do SigV4 signing (we can call it signed, GitHub can't) |

**Both paths are blocked: anonymous is barred by the SCP, and GitHub can't do signed
requests. The Function URL option was abandoned.**

---

## 3. Final Solution: API Gateway (HTTP API)

### 3.1 Why API Gateway bypasses that SCP

The core difference is **who invokes the Lambda, and with which principal**:

| | Lambda Function URL (NONE) | API Gateway (HTTP API) |
|---|---|---|
| Invocation action | `lambda:InvokeFunctionUrl` (anonymous) | `lambda:InvokeFunction` |
| Calling principal | `*` (anonymous) | `apigateway.amazonaws.com` (service principal) |
| Hits the Academy SCP? | **Yes** (anonymous Function URL forbidden) | **No** |

API Gateway accepts GitHub's anonymous HTTPS request on the public internet, then **the API
Gateway service principal** invokes the Lambda — this invocation path uses the
`apigateway.amazonaws.com` principal, not anonymous `lambda:InvokeFunctionUrl`, so it
**does not trigger** the SCP.

Externally it is still a public endpoint (GitHub needs no signing); internally the handler
still authenticates via HMAC-SHA256, so the security model is identical to the original design.

### 3.2 Why HTTP API rather than REST API

- The **payload format 2.0** event shape is **identical to a Lambda Function URL** —
  `event.headers` / `event.body` and returning `{statusCode, body}` are all compatible, so
  the **handler code does not change at all**.
- HTTP API is lighter, cheaper, and needs less configuration — more than enough here.
- The `apigatewayv2` commands ship in the Lab's default CLI (`2.1.11`), so **no CLI upgrade
  is needed** (whereas Function URL had actually required CLI ≥ 2.7).

### 3.3 Deployment logic (steps added to 04-lambda.sh)

The script creates/reuses the following resources idempotently, in order:

```bash
# 1) Create the HTTP API (if one with this name doesn't exist)
API_ID=$(aws apigatewayv2 create-api \
  --name codeguard-webhook-api \
  --protocol-type HTTP \
  --query 'ApiId' --output text)

# 2) AWS_PROXY integration → webhook Lambda (payload 2.0)
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "$WEBHOOK_LAMBDA_ARN" \
  --integration-method POST \
  --payload-format-version 2.0 \
  --query 'IntegrationId' --output text)

# 3) Route POST /webhook → integration
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key 'POST /webhook' \
  --target "integrations/$INTEGRATION_ID"

# 4) $default stage with auto-deploy (no stage prefix in the URL)
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy

# 5) Resource policy: allow API Gateway to invoke this Lambda
aws lambda add-permission \
  --function-name codeguard-webhook-handler \
  --statement-id ApiGatewayInvokeWebhook \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:<ACCOUNT_ID>:$API_ID/*/*/webhook"
```

The resulting endpoint looks like:

```
https://<API_ID>.execute-api.us-east-1.amazonaws.com/webhook
```

Actual endpoint from this deployment: `https://d8hm5l4jpa.execute-api.us-east-1.amazonaws.com/webhook`

Generated resource policy (real output):

```json
{
  "Sid": "ApiGatewayInvokeWebhook",
  "Effect": "Allow",
  "Principal": { "Service": "apigateway.amazonaws.com" },
  "Action": "lambda:InvokeFunction",
  "Resource": "arn:aws:lambda:us-east-1:522518123032:function:codeguard-webhook-handler",
  "Condition": {
    "ArnLike": { "AWS:SourceArn": "arn:aws:execute-api:us-east-1:522518123032:d8hm5l4jpa/*/*/webhook" }
  }
}
```

---

## 4. Files Changed

| File | Change |
|------|--------|
| [infra/04-lambda.sh](infra/04-lambda.sh) | **Core change.** Removed the Function URL block (`create-function-url-config` / `add-permission --action lambda:InvokeFunctionUrl --principal *`) and replaced it with the HTTP API logic above (API / integration / route / `$default` stage / resource policy), all idempotent. Output variable renamed from `WEBHOOK_FUNCTION_URL` to `WEBHOOK_URL`, and `WEBHOOK_API_ID` is saved to state.env; the closing banner was updated to match. |
| [infra/teardown.sh](infra/teardown.sh) | Changed `lambda delete-function-url-config` to `apigatewayv2 delete-api` (prefers `WEBHOOK_API_ID` from state, otherwise looks up the API by name `codeguard-webhook-api` and deletes it). |
| [deploy.sh](deploy.sh) | Step label "Function URL" → "API Gateway"; `WEBHOOK_FUNCTION_URL` → `WEBHOOK_URL` in the closing summary. |
| [infra/config.env](infra/config.env) | Comment: ingress description changed from "Function URL" to "API Gateway HTTP API". |
| [infra/02-security.sh](infra/02-security.sh) | Comment: Lambda is invoked by API Gateway (event-based), no inbound ports needed (wording updated). |
| [README.md](README.md) | Prerequisites (CLI version), Lab notes, deploy summary, GitHub webhook setup steps, architecture diagram, timeline, file tree, resource table, ownership table — all updated from Function URL to API Gateway. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Ingress paragraph, Mermaid diagram node, data-flow table, and ownership table updated to API Gateway. |
| [arc.md](arc.md) | Chinese diagram-spec doc synced (one-line summary, Lab note, main flow, component list, color legend, icon list). |

> **Handler code unchanged**: [lambda-webhook/src/index.js](lambda-webhook/src/index.js) reads
> `event.headers` / `event.body` and returns `{statusCode, body}`, fully compatible with HTTP
> API payload 2.0.

---

## 5. Trigger Flow (end to end)

```
①  Developer opens / updates a PR in kate-xke/test
        │  GitHub sends a pull_request webhook (HTTPS POST, with X-Hub-Signature-256)
        ▼
②  API Gateway (HTTP API, POST /webhook)        ← public HTTPS endpoint (replaces Function URL)
        │  invokes Lambda as the apigateway.amazonaws.com principal (does NOT trigger the Academy SCP)
        ▼
③  λ Webhook Handler                            ← Person A
        ├─ HMAC-SHA256 verification (verify.js)
        ├─ writes S3: jobs/{jobId}/metadata.json (PENDING)
        ├─ returns 202 Accepted to GitHub
        └─ async-invokes the SAST Scanner
        ▼
④  λ SAST Scanner                               ← Person B
        ├─ downloads the repo tarball, runs the regex rule engine
        ├─ writes S3: jobs/{jobId}/report.json (SUCCESS)
        ▼
⑤  S3 ObjectCreated (suffix=report.json) triggers
        ▼
⑥  λ Notifier                                   ← Person C
        ├─ reads report.json
        ├─ calls the GitHub API to post a PR comment (findings summary table)
        └─ if high > 0 → sends an SNS alert email
```

### 5.1 Quick endpoint connectivity check

| Test | Command | Result | Meaning |
|------|---------|--------|---------|
| Unsigned POST | `curl -X POST .../webhook -d '{"zen":"ping"}'` | `HTTP 401` | The request **reached the handler** (HMAC verification failed → 401), proving the SCP is not blocking — exactly what the Function URL could not do (that was a platform-layer 403) |
| GET | `curl .../webhook` | `HTTP 404` | Correct — only `POST /webhook` is routed |

> **Key contrast**: a Function URL (NONE) anonymous request gets `403 Forbidden`
> (platform-layer block, **never enters the code**); an API Gateway anonymous request
> reaches the handler and only returns `401` after HMAC verification fails
> (**application-layer logic**). This 403→401 difference is the direct evidence that the
> approach works.

---

## 6. Real Log Samples (from this deployment's testing)

### 6.1 Webhook Handler — request enters successfully (proves API Gateway works)

```
INFO {"message":"warm-up ping received","source":"aws.events"}
INFO {"message":"Webhook accepted","jobId":"516f1c78-b69f-4884-85a6-1465853d0a45",
      "repo":"kate-xke/test","commitSha":"8571845aac8860c521c60e29ee2e11bb770fae88"}
REPORT Duration: 309.12 ms  Billed Duration: 310 ms  Memory Size: 512 MB
```

### 6.2 SAST Scanner — scan complete

```
INFO Scan start: jobId=4edc1493-6cd0-4754-b6aa-e7fe93f72451 repo=kate-xke/test
     sha=749a9732dcd31848aca53ead62d2799b4199413b
INFO Scan done:  jobId=4edc1493-6cd0-4754-b6aa-e7fe93f72451 findings=10
REPORT Duration: 1531.06 ms  Billed Duration: 1532 ms  Memory Size: 512 MB
```

### 6.3 Notifier — the real troubleshooting progression to success

**(a) First run: GitHub token was still a placeholder → 401**

```
INFO  Notifier triggered: ... jobId=0193c4e7-...
INFO  SNS alert sent for jobId=0193c4e7-... (6 high-severity findings)
ERROR GitHub PR comment failed: GitHub API 401: { "message": "Bad credentials", "status": "401" }
```

**(b) Real token in place, but the warm container cached the old token / fine-grained
permission insufficient → 403**

```
ERROR GitHub PR comment failed: GitHub API 403:
      {"message":"Resource not accessible by personal access token",
       "documentation_url":".../issues/comments#create-an-issue-comment","status":"403"}
```

> Two troubleshooting takeaways:
> 1. The Notifier caches the token in memory via `let cachedToken` (`index.mjs`); an old
>    "warm" container keeps using the stale value — forcing a cold start with
>    `update-function-configuration` makes it re-read SSM.
> 2. A fine-grained PAT needs **Issues: Read and write** permission to post a PR comment
>    (comments go through the issues-comments API).

**(c) Valid token + permission granted + after cold start → success (note: no ERROR before it)**

```
INFO Notifier triggered: ... jobId=4f6e30f5-fb81-45a3-a743-69c49908cc00
INFO SNS alert sent for jobId=4f6e30f5-... (6 high-severity findings)
INFO PR comment posted: repo=kate-xke/test pr=1
```

> Bonus fix: the original Notifier printed `PR comment posted` regardless of success
> (a misleading log). It was changed to `try/catch` — it prints `PR comment posted` only on
> success and logs `ERROR` on failure.

---

## 7. Conclusion

| Dimension | Outcome |
|-----------|---------|
| EC2 in front of Lambda | ❌ Rejected — defeats serverless; standing cost / ops / attack surface |
| Function URL (NONE) | ❌ Creates fine but **anonymous invocation is blocked by the Academy SCP** (403) |
| Function URL (AWS_IAM) | ⚠️ Works when signed, but **GitHub cannot do SigV4 signing** — not applicable |
| **API Gateway (HTTP API)** | ✅ **Adopted** — invoked via the `apigateway.amazonaws.com` principal, does not trigger the SCP; zero handler changes; no CLI upgrade needed |

The full pipeline was verified end to end:
**GitHub → API Gateway → Webhook Handler → SAST Scanner → S3 → Notifier → PR comment + SNS email**.
