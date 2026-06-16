#!/usr/bin/env bash
# 04-lambda.sh — Builds and pushes Docker image to ECR, creates/updates the
#                webhook handler Lambda, exposes it via a public Lambda Function
#                URL (the GitHub webhook target), and sets up EventBridge rules
#                for warm-up pings and SCAN_FAILED retry events.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[04-lambda] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO_URI="${ECR_REGISTRY}/${WEBHOOK_ECR_REPO}"
LAMBDA_DIR="${SCRIPT_DIR}/../lambda-webhook"

# ── ECR: create repository if it does not exist ───────────────────────────────
log "Ensuring ECR repository exists..."
if ! aws ecr describe-repositories \
     --repository-names "${WEBHOOK_ECR_REPO}" \
     --region "${AWS_REGION}" &>/dev/null; then
  aws ecr create-repository \
    --repository-name "${WEBHOOK_ECR_REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --region "${AWS_REGION}" \
    --tags Key=Project,Value="${PROJECT_TAG}"
  log "ECR repository created: ${ECR_REPO_URI}"
else
  log "ECR repository already exists: ${ECR_REPO_URI}"
fi
save ECR_REPO_URI "${ECR_REPO_URI}"

# ── Docker: build and push ─────────────────────────────────────────────────────
log "Authenticating Docker to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

log "Building Docker image..."
docker build \
  --platform linux/amd64 \
  --provenance=false \
  -t "${ECR_REPO_URI}:latest" \
  "${LAMBDA_DIR}"

log "Pushing image to ECR..."
docker push "${ECR_REPO_URI}:latest"

IMAGE_DIGEST=$(aws ecr describe-images \
  --repository-name "${WEBHOOK_ECR_REPO}" \
  --image-ids imageTag=latest \
  --region "${AWS_REGION}" \
  --query 'imageDetails[0].imageDigest' --output text)
log "Image digest: ${IMAGE_DIGEST}"
save ECR_IMAGE_DIGEST "${IMAGE_DIGEST}"

# ── SSM: verify webhook secret exists ─────────────────────────────────────────
# The secret must be pre-populated manually:
#   aws ssm put-parameter --name /codeguard/github-webhook-secret \
#     --value "<YOUR_SECRET>" --type SecureString
log "Verifying SSM parameter ${WEBHOOK_SECRET_PARAM} exists..."
if ! aws ssm get-parameter \
     --name "${WEBHOOK_SECRET_PARAM}" \
     --region "${AWS_REGION}" &>/dev/null; then
  echo ""
  echo "ERROR: SSM parameter ${WEBHOOK_SECRET_PARAM} not found."
  echo "Create it before running this script:"
  echo "  aws ssm put-parameter --name '${WEBHOOK_SECRET_PARAM}' \\"
  echo "    --value '<YOUR_GITHUB_WEBHOOK_SECRET>' \\"
  echo "    --type SecureString --region ${AWS_REGION}"
  exit 1
fi

# ── Lambda: create or update ──────────────────────────────────────────────────
WEBHOOK_LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${WEBHOOK_LAMBDA_NAME}"

EXISTING=$(aws lambda get-function \
  --function-name "${WEBHOOK_LAMBDA_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "")

if [ -z "${EXISTING}" ]; then
  log "Creating Lambda function ${WEBHOOK_LAMBDA_NAME}..."
  aws lambda create-function \
    --function-name "${WEBHOOK_LAMBDA_NAME}" \
    --package-type Image \
    --code ImageUri="${ECR_REPO_URI}:latest" \
    --role "${LAMBDA_ROLE_ARN}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${WEBHOOK_LAMBDA_TIMEOUT}" \
    --vpc-config "SubnetIds=${PRIVATE_SUBNET_ID},SecurityGroupIds=${LAMBDA_SG_ID}" \
    --environment "Variables={S3_BUCKET_NAME=${S3_BUCKET_NAME},SAST_LAMBDA_NAME=${SAST_LAMBDA_NAME},AWS_REGION_NAME=${AWS_REGION},WEBHOOK_SECRET_PARAM=${WEBHOOK_SECRET_PARAM},SNS_TOPIC_ARN=${SNS_TOPIC_ARN}}" \
    --tags "Project=${PROJECT_TAG}" \
    --region "${AWS_REGION}"

  log "Waiting for Lambda to become active..."
  aws lambda wait function-active \
    --function-name "${WEBHOOK_LAMBDA_NAME}" \
    --region "${AWS_REGION}"
else
  log "Updating existing Lambda function code..."
  aws lambda update-function-code \
    --function-name "${WEBHOOK_LAMBDA_NAME}" \
    --image-uri "${ECR_REPO_URI}:latest" \
    --region "${AWS_REGION}"

  aws lambda wait function-updated \
    --function-name "${WEBHOOK_LAMBDA_NAME}" \
    --region "${AWS_REGION}"

  log "Updating Lambda configuration..."
  aws lambda update-function-configuration \
    --function-name "${WEBHOOK_LAMBDA_NAME}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${WEBHOOK_LAMBDA_TIMEOUT}" \
    --vpc-config "SubnetIds=${PRIVATE_SUBNET_ID},SecurityGroupIds=${LAMBDA_SG_ID}" \
    --environment "Variables={S3_BUCKET_NAME=${S3_BUCKET_NAME},SAST_LAMBDA_NAME=${SAST_LAMBDA_NAME},AWS_REGION_NAME=${AWS_REGION},WEBHOOK_SECRET_PARAM=${WEBHOOK_SECRET_PARAM},SNS_TOPIC_ARN=${SNS_TOPIC_ARN}}" \
    --region "${AWS_REGION}"

  aws lambda wait function-updated \
    --function-name "${WEBHOOK_LAMBDA_NAME}" \
    --region "${AWS_REGION}"
fi

# Configure async invocation retry policy
log "Configuring async invocation retry policy (MaximumRetryAttempts=2)..."
aws lambda put-function-event-invoke-config \
  --function-name "${WEBHOOK_LAMBDA_NAME}" \
  --maximum-retry-attempts 2 \
  --region "${AWS_REGION}"

save WEBHOOK_LAMBDA_ARN "${WEBHOOK_LAMBDA_ARN}"

# ── API Gateway (HTTP API): the GitHub webhook endpoint ───────────────────────
# GitHub posts the webhook here; API Gateway proxies it to the Lambda. We use an
# HTTP API with payload format 2.0 — the same event shape a Function URL emits,
# so the handler (event.headers / event.body) needs no changes. The endpoint is
# publicly reachable without SigV4 (GitHub can't sign requests); the handler
# itself authenticates every request via HMAC-SHA256 (verify.js).
#
# Why not a Lambda Function URL? The Academy Lab SCP forbids invoking a Function
# URL anonymously (AuthType=NONE) — anonymous requests are rejected with 403 at
# the AWS platform layer before reaching the code. API Gateway invokes the
# Lambda via the apigateway.amazonaws.com principal, not lambda:InvokeFunctionUrl,
# so it is not blocked by that SCP.
WEBHOOK_API_NAME="codeguard-webhook-api"
WEBHOOK_ROUTE_KEY="POST /webhook"

log "Creating/ensuring HTTP API Gateway for webhook handler..."
API_ID=$(aws apigatewayv2 get-apis \
  --region "${AWS_REGION}" \
  --query "Items[?Name=='${WEBHOOK_API_NAME}'].ApiId | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "${API_ID}" = "None" ] || [ -z "${API_ID}" ]; then
  API_ID=$(aws apigatewayv2 create-api \
    --name "${WEBHOOK_API_NAME}" \
    --protocol-type HTTP \
    --description "CodeGuard GitHub webhook ingress (replaces Lambda Function URL)" \
    --tags "Project=${PROJECT_TAG}" \
    --region "${AWS_REGION}" \
    --query 'ApiId' --output text)
  log "Created HTTP API: ${API_ID}"
else
  log "HTTP API already exists: ${API_ID}"
fi
save WEBHOOK_API_ID "${API_ID}"

# Integration: AWS_PROXY → webhook Lambda (payload format 2.0)
INTEGRATION_ID=$(aws apigatewayv2 get-integrations \
  --api-id "${API_ID}" \
  --region "${AWS_REGION}" \
  --query "Items[?IntegrationUri=='${WEBHOOK_LAMBDA_ARN}'].IntegrationId | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "${INTEGRATION_ID}" = "None" ] || [ -z "${INTEGRATION_ID}" ]; then
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "${API_ID}" \
    --integration-type AWS_PROXY \
    --integration-uri "${WEBHOOK_LAMBDA_ARN}" \
    --integration-method POST \
    --payload-format-version 2.0 \
    --region "${AWS_REGION}" \
    --query 'IntegrationId' --output text)
  log "Created integration: ${INTEGRATION_ID}"
else
  log "Integration already exists: ${INTEGRATION_ID}"
fi

# Route: POST /webhook → integration
ROUTE_ID=$(aws apigatewayv2 get-routes \
  --api-id "${API_ID}" \
  --region "${AWS_REGION}" \
  --query "Items[?RouteKey=='${WEBHOOK_ROUTE_KEY}'].RouteId | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "${ROUTE_ID}" = "None" ] || [ -z "${ROUTE_ID}" ]; then
  aws apigatewayv2 create-route \
    --api-id "${API_ID}" \
    --route-key "${WEBHOOK_ROUTE_KEY}" \
    --target "integrations/${INTEGRATION_ID}" \
    --region "${AWS_REGION}" >/dev/null
  log "Created route: ${WEBHOOK_ROUTE_KEY}"
else
  log "Route already exists: ${WEBHOOK_ROUTE_KEY}"
fi

# Stage: $default with auto-deploy (no stage prefix in the URL)
if ! aws apigatewayv2 get-stage \
     --api-id "${API_ID}" \
     --stage-name '$default' \
     --region "${AWS_REGION}" &>/dev/null; then
  aws apigatewayv2 create-stage \
    --api-id "${API_ID}" \
    --stage-name '$default' \
    --auto-deploy \
    --region "${AWS_REGION}" >/dev/null
  log "Created \$default stage (auto-deploy)"
else
  log "\$default stage already exists"
fi

# Resource policy: allow API Gateway to invoke the Lambda. Idempotent.
aws lambda add-permission \
  --function-name "${WEBHOOK_LAMBDA_NAME}" \
  --statement-id ApiGatewayInvokeWebhook \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*/webhook" \
  --region "${AWS_REGION}" 2>/dev/null || true

WEBHOOK_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/webhook"
log "Webhook endpoint (API Gateway): ${WEBHOOK_URL}"
save WEBHOOK_URL "${WEBHOOK_URL}"

# ── EventBridge: warm-up ping every 5 minutes ─────────────────────────────────
log "Creating EventBridge warm-up rule (rate 5 minutes)..."
WARMUP_RULE_ARN=$(aws events put-rule \
  --name codeguard-lambda-warmup \
  --schedule-expression "rate(5 minutes)" \
  --state ENABLED \
  --description "Keeps CodeGuard webhook handler Lambda warm to minimise cold starts" \
  --region "${AWS_REGION}" \
  --query 'RuleArn' --output text)

aws events put-targets \
  --rule codeguard-lambda-warmup \
  --targets "[{\"Id\":\"WebhookHandlerWarmup\",\"Arn\":\"${WEBHOOK_LAMBDA_ARN}\",\"Input\":\"{\\\"source\\\":\\\"aws.events\\\",\\\"detail-type\\\":\\\"warmup\\\"}\"}]" \
  --region "${AWS_REGION}"

aws lambda add-permission \
  --function-name "${WEBHOOK_LAMBDA_NAME}" \
  --statement-id AllowEventBridgeWarmup \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "${WARMUP_RULE_ARN}" \
  --region "${AWS_REGION}" 2>/dev/null || true

log "Warm-up rule created: ${WARMUP_RULE_ARN}"
save WARMUP_RULE_ARN "${WARMUP_RULE_ARN}"

# ── EventBridge: SCAN_FAILED retry rule ───────────────────────────────────────
# This rule is triggered when Person B's SAST Scanner publishes a
# SCAN_FAILED custom event to the default event bus. The webhook handler
# re-reads S3 metadata, increments retryCount, and re-invokes the scanner.
log "Creating EventBridge SCAN_FAILED retry rule..."
RETRY_RULE_ARN=$(aws events put-rule \
  --name codeguard-scan-failed-retry \
  --event-pattern '{
    "source": ["codeguard.scanner"],
    "detail-type": ["SCAN_FAILED"]
  }' \
  --state ENABLED \
  --description "Triggers webhook handler to retry failed SAST scans (max 3 total attempts)" \
  --region "${AWS_REGION}" \
  --query 'RuleArn' --output text)

aws events put-targets \
  --rule codeguard-scan-failed-retry \
  --targets "[{\"Id\":\"WebhookHandlerRetry\",\"Arn\":\"${WEBHOOK_LAMBDA_ARN}\"}]" \
  --region "${AWS_REGION}"

aws lambda add-permission \
  --function-name "${WEBHOOK_LAMBDA_NAME}" \
  --statement-id AllowEventBridgeRetry \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "${RETRY_RULE_ARN}" \
  --region "${AWS_REGION}" 2>/dev/null || true

log "Retry rule created: ${RETRY_RULE_ARN}"
save RETRY_RULE_ARN "${RETRY_RULE_ARN}"

log ""
log "╔═══════════════════════════════════════════════════════════════╗"
log "║  Public webhook endpoint (API Gateway HTTP API):             ║"
log "║    ${WEBHOOK_URL}"
log "║  Configure the GitHub webhook to POST to this HTTPS URL.      ║"
log "╚═══════════════════════════════════════════════════════════════╝"

log "04-lambda.sh complete."
