#!/usr/bin/env bash
# 07-lambda-scanner.sh — Builds and pushes the SAST Scanner Docker image to ECR,
#                        then creates/updates the scanner Lambda function.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[07-lambda-scanner] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SCANNER_ECR_URI="${ECR_REGISTRY}/${SCANNER_ECR_REPO}"
SCANNER_DIR="${SCRIPT_DIR}/../lambda-scanner"
SCANNER_LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${SAST_LAMBDA_NAME}"

# ── Verify GitHub token SSM param exists ─────────────────────────────────────
log "Verifying SSM parameter ${GITHUB_TOKEN_PARAM} exists..."
if ! aws ssm get-parameter \
     --name "${GITHUB_TOKEN_PARAM}" \
     --region "${AWS_REGION}" &>/dev/null; then
  echo ""
  echo "ERROR: SSM parameter ${GITHUB_TOKEN_PARAM} not found."
  echo "Create it before running this script:"
  echo "  aws ssm put-parameter --name '${GITHUB_TOKEN_PARAM}' \\"
  echo "    --value '<YOUR_GITHUB_PERSONAL_ACCESS_TOKEN>' \\"
  echo "    --type SecureString --region ${AWS_REGION}"
  exit 1
fi

# ── ECR: create repository if it does not exist ───────────────────────────────
log "Ensuring ECR repository exists: ${SCANNER_ECR_REPO}..."
if ! aws ecr describe-repositories \
     --repository-names "${SCANNER_ECR_REPO}" \
     --region "${AWS_REGION}" &>/dev/null; then
  aws ecr create-repository \
    --repository-name "${SCANNER_ECR_REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --region "${AWS_REGION}" \
    --tags Key=Project,Value="${PROJECT_TAG}"
  log "ECR repository created: ${SCANNER_ECR_URI}"
else
  log "ECR repository already exists: ${SCANNER_ECR_URI}"
fi
save SCANNER_ECR_URI "${SCANNER_ECR_URI}"

# ── Docker: build and push ─────────────────────────────────────────────────────
log "Authenticating Docker to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

log "Building SAST Scanner Docker image (linux/amd64)..."
docker build \
  --platform linux/amd64 \
  -t "${SCANNER_ECR_URI}:latest" \
  "${SCANNER_DIR}"

log "Pushing image to ECR..."
docker push "${SCANNER_ECR_URI}:latest"

SCANNER_IMAGE_DIGEST=$(aws ecr describe-images \
  --repository-name "${SCANNER_ECR_REPO}" \
  --image-ids imageTag=latest \
  --region "${AWS_REGION}" \
  --query 'imageDetails[0].imageDigest' --output text)
log "Scanner image digest: ${SCANNER_IMAGE_DIGEST}"

# ── Lambda: create or update ──────────────────────────────────────────────────
EXISTING=$(aws lambda get-function \
  --function-name "${SAST_LAMBDA_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "")

if [ -z "${EXISTING}" ]; then
  log "Creating Lambda function ${SAST_LAMBDA_NAME}..."
  aws lambda create-function \
    --function-name "${SAST_LAMBDA_NAME}" \
    --package-type Image \
    --code ImageUri="${SCANNER_ECR_URI}:latest" \
    --role "${LAMBDA_ROLE_ARN}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${SCANNER_LAMBDA_TIMEOUT}" \
    --vpc-config "SubnetIds=${PRIVATE_SUBNET_ID},SecurityGroupIds=${LAMBDA_SG_ID}" \
    --environment "Variables={S3_BUCKET_NAME=${S3_BUCKET_NAME},GITHUB_TOKEN_PARAM=${GITHUB_TOKEN_PARAM}}" \
    --tags "Project=${PROJECT_TAG}" \
    --region "${AWS_REGION}"

  log "Waiting for Lambda to become active..."
  aws lambda wait function-active \
    --function-name "${SAST_LAMBDA_NAME}" \
    --region "${AWS_REGION}"
else
  log "Updating existing scanner Lambda code..."
  aws lambda update-function-code \
    --function-name "${SAST_LAMBDA_NAME}" \
    --image-uri "${SCANNER_ECR_URI}:latest" \
    --region "${AWS_REGION}"

  aws lambda wait function-updated \
    --function-name "${SAST_LAMBDA_NAME}" \
    --region "${AWS_REGION}"

  log "Updating scanner Lambda configuration..."
  aws lambda update-function-configuration \
    --function-name "${SAST_LAMBDA_NAME}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${SCANNER_LAMBDA_TIMEOUT}" \
    --vpc-config "SubnetIds=${PRIVATE_SUBNET_ID},SecurityGroupIds=${LAMBDA_SG_ID}" \
    --environment "Variables={S3_BUCKET_NAME=${S3_BUCKET_NAME},GITHUB_TOKEN_PARAM=${GITHUB_TOKEN_PARAM}}" \
    --region "${AWS_REGION}"

  aws lambda wait function-updated \
    --function-name "${SAST_LAMBDA_NAME}" \
    --region "${AWS_REGION}"
fi

save SCANNER_LAMBDA_ARN "${SCANNER_LAMBDA_ARN}"

# Allow webhook handler to invoke scanner
log "Granting webhook handler permission to invoke scanner..."
aws lambda add-permission \
  --function-name "${SAST_LAMBDA_NAME}" \
  --statement-id AllowWebhookInvoke \
  --action lambda:InvokeFunction \
  --principal lambda.amazonaws.com \
  --source-arn "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${WEBHOOK_LAMBDA_NAME}" \
  --region "${AWS_REGION}" 2>/dev/null || true

# ── EventBridge: warm-up ping every 5 minutes ─────────────────────────────────
log "Creating EventBridge warm-up rule for scanner..."
SCANNER_WARMUP_RULE_ARN=$(aws events put-rule \
  --name codeguard-scanner-warmup \
  --schedule-expression "rate(5 minutes)" \
  --state ENABLED \
  --description "Keeps CodeGuard SAST scanner Lambda warm" \
  --region "${AWS_REGION}" \
  --query 'RuleArn' --output text)

aws events put-targets \
  --rule codeguard-scanner-warmup \
  --targets "Id=SastScannerWarmup,Arn=${SCANNER_LAMBDA_ARN},Input={\"source\":\"aws.events\",\"detail-type\":\"warmup\"}" \
  --region "${AWS_REGION}"

aws lambda add-permission \
  --function-name "${SAST_LAMBDA_NAME}" \
  --statement-id AllowEventBridgeScannerWarmup \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "${SCANNER_WARMUP_RULE_ARN}" \
  --region "${AWS_REGION}" 2>/dev/null || true

log "Scanner warm-up rule: ${SCANNER_WARMUP_RULE_ARN}"

log "07-lambda-scanner.sh complete."
