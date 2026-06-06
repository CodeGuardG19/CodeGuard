#!/usr/bin/env bash
# teardown.sh — Deletes all CodeGuard resources in safe reverse order.
# Prints each step before executing. On failure, prints the failed resource
# and continues rather than stopping.
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

run() {
  local desc="$1"; shift
  step "${desc}"
  if "$@" 2>&1; then
    ok "${desc}"
  else
    fail "${desc}"
  fi
}

# ── Lambda resources ───────────────────────────────────────────────────────────
step "Removing EventBridge targets and rules..."
aws events remove-targets \
  --rule codeguard-lambda-warmup \
  --ids WebhookHandlerWarmup \
  --region "${AWS_REGION}" 2>/dev/null && ok "Warmup rule targets removed" || fail "Warmup rule targets"
aws events delete-rule \
  --name codeguard-lambda-warmup \
  --region "${AWS_REGION}" 2>/dev/null && ok "Warmup rule deleted" || fail "Warmup rule"

aws events remove-targets \
  --rule codeguard-scan-failed-retry \
  --ids WebhookHandlerRetry \
  --region "${AWS_REGION}" 2>/dev/null && ok "Retry rule targets removed" || fail "Retry rule targets"
aws events delete-rule \
  --name codeguard-scan-failed-retry \
  --region "${AWS_REGION}" 2>/dev/null && ok "Retry rule deleted" || fail "Retry rule"

step "Deleting Lambda Function URL..."
aws lambda delete-function-url-config \
  --function-name "${WEBHOOK_LAMBDA_NAME:-codeguard-webhook-handler}" \
  --region "${AWS_REGION}" 2>/dev/null && ok "Function URL deleted" || fail "Function URL"

step "Deleting Lambda function..."
aws lambda delete-function \
  --function-name "${WEBHOOK_LAMBDA_NAME:-codeguard-webhook-handler}" \
  --region "${AWS_REGION}" 2>/dev/null && ok "Lambda deleted" || fail "Lambda"

# ── CloudWatch alarms and log groups ──────────────────────────────────────────
step "Deleting CloudWatch alarms..."
aws cloudwatch delete-alarms \
  --alarm-names \
    codeguard-lambda-error-rate \
    codeguard-lambda-p95-duration \
    codeguard-ec2-cpu-high \
  --region "${AWS_REGION}" 2>/dev/null && ok "Alarms deleted" || fail "Alarms"

step "Deleting CloudWatch log groups..."
for LG in \
  "/codeguard/lambda/webhook-handler" \
  "/codeguard/ec2/nginx-access" \
  "/codeguard/ec2/nginx-error"; do
  aws logs delete-log-group \
    --log-group-name "${LG}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "Log group ${LG} deleted" || fail "Log group ${LG}"
done

# ── ECR repository ─────────────────────────────────────────────────────────────
step "Deleting ECR repository (force — removes all images)..."
aws ecr delete-repository \
  --repository-name "${ECR_REPO_NAME:-codeguard-webhook-handler}" \
  --force \
  --region "${AWS_REGION}" 2>/dev/null && ok "ECR repository deleted" || fail "ECR repository"

# ── EC2 instance and Elastic IP ───────────────────────────────────────────────
if [ -n "${EC2_INSTANCE_ID:-}" ]; then
  step "Terminating EC2 instance ${EC2_INSTANCE_ID}..."
  aws ec2 terminate-instances \
    --instance-ids "${EC2_INSTANCE_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "EC2 termination initiated" || fail "EC2 termination"

  echo "  Waiting for EC2 to terminate..."
  aws ec2 wait instance-terminated \
    --instance-ids "${EC2_INSTANCE_ID}" \
    --region "${AWS_REGION}" 2>/dev/null || fail "EC2 wait terminated"
fi

if [ -n "${EC2_EIP_ALLOC_ID:-}" ]; then
  step "Releasing EC2 Elastic IP ${EC2_EIP_ALLOC_ID}..."
  aws ec2 release-address \
    --allocation-id "${EC2_EIP_ALLOC_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "EC2 EIP released" || fail "EC2 EIP"
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
step "Deleting IAM roles and policies..."

aws iam delete-role-policy \
  --role-name codeguard-lambda-webhook-role \
  --policy-name codeguard-lambda-webhook-policy 2>/dev/null || true
aws iam detach-role-policy \
  --role-name codeguard-lambda-webhook-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole 2>/dev/null || true
aws iam delete-role \
  --role-name codeguard-lambda-webhook-role 2>/dev/null && ok "Lambda role deleted" || fail "Lambda role"

aws iam remove-role-from-instance-profile \
  --instance-profile-name codeguard-ec2-instance-profile \
  --role-name codeguard-ec2-ssm-role 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name codeguard-ec2-instance-profile 2>/dev/null || true
aws iam detach-role-policy \
  --role-name codeguard-ec2-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
aws iam detach-role-policy \
  --role-name codeguard-ec2-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
aws iam delete-role \
  --role-name codeguard-ec2-ssm-role 2>/dev/null && ok "EC2 role deleted" || fail "EC2 role"

aws iam delete-role-policy \
  --role-name codeguard-gha-deploy-role \
  --policy-name codeguard-gha-deploy-policy 2>/dev/null || true
aws iam delete-role \
  --role-name codeguard-gha-deploy-role 2>/dev/null && ok "GHA role deleted" || fail "GHA role"

# ── NAT Gateway and NAT EIP ───────────────────────────────────────────────────
if [ -n "${NAT_GW_ID:-}" ]; then
  step "Deleting NAT Gateway ${NAT_GW_ID}..."
  aws ec2 delete-nat-gateway \
    --nat-gateway-id "${NAT_GW_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "NAT Gateway delete initiated" || fail "NAT Gateway"

  echo "  Waiting for NAT Gateway to be deleted (may take ~1 minute)..."
  aws ec2 wait nat-gateway-deleted \
    --nat-gateway-ids "${NAT_GW_ID}" \
    --region "${AWS_REGION}" 2>/dev/null || fail "NAT Gateway wait deleted"
fi

if [ -n "${NAT_EIP_ALLOC_ID:-}" ]; then
  step "Releasing NAT Elastic IP ${NAT_EIP_ALLOC_ID}..."
  aws ec2 release-address \
    --allocation-id "${NAT_EIP_ALLOC_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "NAT EIP released" || fail "NAT EIP"
fi

# ── VPC Endpoints ─────────────────────────────────────────────────────────────
for EP_ID in "${SNS_ENDPOINT_ID:-}" "${S3_ENDPOINT_ID:-}"; do
  if [ -n "${EP_ID}" ]; then
    step "Deleting VPC endpoint ${EP_ID}..."
    aws ec2 delete-vpc-endpoints \
      --vpc-endpoint-ids "${EP_ID}" \
      --region "${AWS_REGION}" 2>/dev/null && ok "Endpoint ${EP_ID} deleted" || fail "Endpoint ${EP_ID}"
  fi
done

# ── Security Groups ────────────────────────────────────────────────────────────
for SG_ID in "${LAMBDA_SG_ID:-}" "${EC2_SG_ID:-}" "${SNS_ENDPOINT_SG_ID:-}"; do
  if [ -n "${SG_ID}" ]; then
    step "Deleting security group ${SG_ID}..."
    aws ec2 delete-security-group \
      --group-id "${SG_ID}" \
      --region "${AWS_REGION}" 2>/dev/null && ok "SG ${SG_ID} deleted" || fail "SG ${SG_ID}"
  fi
done

# ── Subnets ───────────────────────────────────────────────────────────────────
for SUBNET_ID in "${PRIVATE_SUBNET_ID:-}" "${PUBLIC_SUBNET_ID:-}"; do
  if [ -n "${SUBNET_ID}" ]; then
    step "Deleting subnet ${SUBNET_ID}..."
    aws ec2 delete-subnet \
      --subnet-id "${SUBNET_ID}" \
      --region "${AWS_REGION}" 2>/dev/null && ok "Subnet ${SUBNET_ID} deleted" || fail "Subnet ${SUBNET_ID}"
  fi
done

# ── Route Tables ──────────────────────────────────────────────────────────────
for RT_ID in "${PRIVATE_RT_ID:-}" "${PUBLIC_RT_ID:-}"; do
  if [ -n "${RT_ID}" ]; then
    step "Deleting route table ${RT_ID}..."
    aws ec2 delete-route-table \
      --route-table-id "${RT_ID}" \
      --region "${AWS_REGION}" 2>/dev/null && ok "Route table ${RT_ID} deleted" || fail "Route table ${RT_ID}"
  fi
done

# ── Internet Gateway ──────────────────────────────────────────────────────────
if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  step "Detaching and deleting Internet Gateway ${IGW_ID}..."
  aws ec2 detach-internet-gateway \
    --internet-gateway-id "${IGW_ID}" \
    --vpc-id "${VPC_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "IGW detached" || fail "IGW detach"
  aws ec2 delete-internet-gateway \
    --internet-gateway-id "${IGW_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "IGW deleted" || fail "IGW delete"
fi

# ── VPC ───────────────────────────────────────────────────────────────────────
if [ -n "${VPC_ID:-}" ]; then
  step "Deleting VPC ${VPC_ID}..."
  aws ec2 delete-vpc \
    --vpc-id "${VPC_ID}" \
    --region "${AWS_REGION}" 2>/dev/null && ok "VPC deleted" || fail "VPC"
fi

# ── Cleanup state file ────────────────────────────────────────────────────────
step "Removing state file..."
rm -f "${STATE_FILE}" && ok "state.env removed" || fail "state.env removal"

echo ""
if [ "${ERRORS}" -gt 0 ]; then
  echo "⚠  Teardown completed with ${ERRORS} error(s). Review output above."
  exit 1
else
  echo "✓  Teardown complete. All CodeGuard resources deleted."
fi
