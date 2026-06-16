#!/usr/bin/env bash
# teardown.sh — Deletes all CodeGuard resources in safe reverse order.
# Prints each step before executing. On failure, prints the resource and continues.
#
# Key ordering rules:
#   1. Lambdas must be deleted before their ENIs can be released from the subnets
#   2. NAT Gateway must be deleted and reach 'deleted' state before releasing its EIP
#   3. VPC endpoints must finish deleting before the VPC can be removed
#   4. All ENIs must be gone before security groups and subnets can be deleted
#   5. IGW must be detached before VPC deletion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

STATE_FILE="${SCRIPT_DIR}/state.env"
if [ -f "${STATE_FILE}" ]; then
  source "${STATE_FILE}"
fi

ERRORS=0

step() { echo ""; echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ FAILED: $*"; ERRORS=$((ERRORS + 1)); }
try()  {
  local desc="$1"; shift
  "$@" 2>/dev/null && ok "${desc}" || fail "${desc}"
}

# ── EventBridge rules (must go before Lambdas) ────────────────────────────────
step "Removing EventBridge targets and rules..."
try "Webhook warmup targets"    aws events remove-targets --rule codeguard-lambda-warmup       --ids WebhookHandlerWarmup    --region "${AWS_REGION}"
try "Webhook warmup rule"       aws events delete-rule    --name codeguard-lambda-warmup                                      --region "${AWS_REGION}"
try "Retry rule targets"        aws events remove-targets --rule codeguard-scan-failed-retry   --ids WebhookHandlerRetry     --region "${AWS_REGION}"
try "Retry rule"                aws events delete-rule    --name codeguard-scan-failed-retry                                  --region "${AWS_REGION}"
try "Scanner warmup targets"    aws events remove-targets --rule codeguard-scanner-warmup      --ids SastScannerWarmup       --region "${AWS_REGION}"
try "Scanner warmup rule"       aws events delete-rule    --name codeguard-scanner-warmup                                    --region "${AWS_REGION}"

# ── API Gateway (webhook ingress) ─────────────────────────────────────────────
step "Deleting API Gateway HTTP API..."
WEBHOOK_API_ID="${WEBHOOK_API_ID:-}"
if [ -z "${WEBHOOK_API_ID}" ]; then
  WEBHOOK_API_ID=$(aws apigatewayv2 get-apis \
    --region "${AWS_REGION}" \
    --query "Items[?Name=='codeguard-webhook-api'].ApiId | [0]" \
    --output text 2>/dev/null || echo "None")
fi
if [ -n "${WEBHOOK_API_ID}" ] && [ "${WEBHOOK_API_ID}" != "None" ]; then
  try "Webhook API Gateway (${WEBHOOK_API_ID})" aws apigatewayv2 delete-api \
    --api-id "${WEBHOOK_API_ID}" --region "${AWS_REGION}"
else
  ok "No API Gateway to delete"
fi

# ── Lambda functions ───────────────────────────────────────────────────────────
step "Deleting Lambda functions..."
try "Webhook Lambda" aws lambda delete-function \
  --function-name "${WEBHOOK_LAMBDA_NAME:-codeguard-webhook-handler}" --region "${AWS_REGION}"
try "Scanner Lambda" aws lambda delete-function \
  --function-name "${SAST_LAMBDA_NAME:-codeguard-sast-scanner}" --region "${AWS_REGION}"
try "Notifier Lambda" aws lambda delete-function \
  --function-name "${NOTIFIER_LAMBDA_NAME:-codeguard-notifier}" --region "${AWS_REGION}"

# ── Wait for Lambda ENIs to be released ───────────────────────────────────────
# AWS takes up to 5 minutes to delete the ENIs Lambda created for VPC access.
# Without this wait, security group and subnet deletion will fail with DependencyViolation.
step "Waiting for Lambda VPC ENIs to be released (up to 5 min)..."
if [ -n "${VPC_ID:-}" ]; then
  for i in $(seq 1 30); do
    ENI_COUNT=$(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
                "Name=interface-type,Values=lambda" \
      --query 'length(NetworkInterfaces)' \
      --output text --region "${AWS_REGION}" 2>/dev/null || echo "0")
    if [ "${ENI_COUNT}" = "0" ]; then
      ok "All Lambda ENIs released."
      break
    fi
    echo "  ${ENI_COUNT} Lambda ENI(s) still present (attempt ${i}/30), waiting 10s..."
    sleep 10
  done
fi

# ── CloudWatch alarms ─────────────────────────────────────────────────────────
step "Deleting CloudWatch alarms..."
try "CloudWatch alarms" aws cloudwatch delete-alarms \
  --alarm-names \
    codeguard-lambda-error-rate \
    codeguard-lambda-p95-duration \
    codeguard-scanner-error-rate \
    codeguard-notifier-error-rate \
  --region "${AWS_REGION}"

# ── CloudWatch log groups ─────────────────────────────────────────────────────
step "Deleting CloudWatch log groups..."
for LG in \
  "/codeguard/lambda/webhook-handler" \
  "/codeguard/lambda/sast-scanner" \
  "/codeguard/lambda/notifier"; do
  try "Log group ${LG}" aws logs delete-log-group \
    --log-group-name "${LG}" --region "${AWS_REGION}"
done

# ── ECR repositories ──────────────────────────────────────────────────────────
step "Deleting ECR repositories..."
try "Webhook ECR repo" aws ecr delete-repository \
  --repository-name "${WEBHOOK_ECR_REPO:-codeguard-webhook-handler}" \
  --force --region "${AWS_REGION}"
try "Scanner ECR repo" aws ecr delete-repository \
  --repository-name "${SCANNER_ECR_REPO:-codeguard-sast-scanner}" \
  --force --region "${AWS_REGION}"

# ── SSM parameters ────────────────────────────────────────────────────────────
step "Deleting SSM parameters..."
try "Webhook secret param"  aws ssm delete-parameter --name "${WEBHOOK_SECRET_PARAM:-/codeguard/github-webhook-secret}" --region "${AWS_REGION}"
try "GitHub token param"    aws ssm delete-parameter --name "${GITHUB_TOKEN_PARAM:-/codeguard/github-token}"            --region "${AWS_REGION}"

# ── IAM ───────────────────────────────────────────────────────────────────────
# LabRole and LabInstanceProfile are course-managed — not deleted.
step "Skipping IAM role deletion (LabRole is course-managed)"
ok "IAM roles skipped"

# ── NAT Gateway ───────────────────────────────────────────────────────────────
if [ -n "${NAT_GW_ID:-}" ]; then
  step "Deleting NAT Gateway ${NAT_GW_ID}..."
  try "NAT Gateway delete" aws ec2 delete-nat-gateway \
    --nat-gateway-id "${NAT_GW_ID}" --region "${AWS_REGION}"
  echo "  Waiting for NAT Gateway to reach deleted state (up to 2 min)..."
  aws ec2 wait nat-gateway-deleted \
    --nat-gateway-ids "${NAT_GW_ID}" --region "${AWS_REGION}" 2>/dev/null \
    && ok "NAT Gateway deleted" || fail "NAT Gateway wait"
fi

if [ -n "${NAT_EIP_ALLOC_ID:-}" ]; then
  step "Releasing NAT Elastic IP..."
  try "NAT EIP release" aws ec2 release-address \
    --allocation-id "${NAT_EIP_ALLOC_ID}" --region "${AWS_REGION}"
fi

# ── VPC Endpoints ─────────────────────────────────────────────────────────────
step "Deleting VPC endpoints..."
EP_IDS=()
[ -n "${SNS_ENDPOINT_ID:-}" ] && EP_IDS+=("${SNS_ENDPOINT_ID}")
[ -n "${S3_ENDPOINT_ID:-}"  ] && EP_IDS+=("${S3_ENDPOINT_ID}")

if [ "${#EP_IDS[@]}" -gt 0 ]; then
  try "VPC endpoints delete" aws ec2 delete-vpc-endpoints \
    --vpc-endpoint-ids "${EP_IDS[@]}" --region "${AWS_REGION}"

  echo "  Waiting for VPC endpoints to finish deleting..."
  for i in $(seq 1 18); do
    PENDING=$(aws ec2 describe-vpc-endpoints \
      --vpc-endpoint-ids "${EP_IDS[@]}" \
      --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
      --output text --region "${AWS_REGION}" 2>/dev/null || echo "")
    if [ -z "${PENDING}" ]; then
      ok "VPC endpoints deleted."
      break
    fi
    echo "  Still deleting: ${PENDING} (attempt ${i}/18), waiting 10s..."
    sleep 10
  done
fi

# ── Security Groups ────────────────────────────────────────────────────────────
step "Deleting security groups..."
for SG_ID in "${LAMBDA_SG_ID:-}" "${SNS_ENDPOINT_SG_ID:-}"; do
  [ -z "${SG_ID}" ] && continue
  try "Security group ${SG_ID}" aws ec2 delete-security-group \
    --group-id "${SG_ID}" --region "${AWS_REGION}"
done

# ── Subnets ───────────────────────────────────────────────────────────────────
step "Deleting subnets..."
for SUBNET_ID in "${PRIVATE_SUBNET_ID:-}" "${PUBLIC_SUBNET_ID:-}"; do
  [ -z "${SUBNET_ID}" ] && continue
  try "Subnet ${SUBNET_ID}" aws ec2 delete-subnet \
    --subnet-id "${SUBNET_ID}" --region "${AWS_REGION}"
done

# ── Route Tables ──────────────────────────────────────────────────────────────
step "Deleting route tables..."
for RT_ID in "${PRIVATE_RT_ID:-}" "${PUBLIC_RT_ID:-}"; do
  [ -z "${RT_ID}" ] && continue
  try "Route table ${RT_ID}" aws ec2 delete-route-table \
    --route-table-id "${RT_ID}" --region "${AWS_REGION}"
done

# ── Internet Gateway ──────────────────────────────────────────────────────────
if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  step "Detaching and deleting Internet Gateway ${IGW_ID}..."
  try "IGW detach" aws ec2 detach-internet-gateway \
    --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" --region "${AWS_REGION}"
  try "IGW delete" aws ec2 delete-internet-gateway \
    --internet-gateway-id "${IGW_ID}" --region "${AWS_REGION}"
fi

# ── VPC ───────────────────────────────────────────────────────────────────────
if [ -n "${VPC_ID:-}" ]; then
  step "Deleting VPC ${VPC_ID}..."
  try "VPC delete" aws ec2 delete-vpc \
    --vpc-id "${VPC_ID}" --region "${AWS_REGION}"
fi

# ── State file ────────────────────────────────────────────────────────────────
step "Removing state file..."
rm -f "${STATE_FILE}" && ok "state.env removed" || fail "state.env removal"

echo ""
if [ "${ERRORS}" -gt 0 ]; then
  echo "⚠  Teardown completed with ${ERRORS} error(s). Review output above."
  exit 1
else
  echo "✓  Teardown complete. All CodeGuard resources deleted."
fi
