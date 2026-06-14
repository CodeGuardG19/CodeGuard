#!/usr/bin/env bash
# teardown.sh — Tears down all CodeGuard resources (reverse deploy order).
# WARNING: This permanently deletes all infrastructure. S3 objects are preserved
#          unless you pass --delete-s3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${SCRIPT_DIR}/infra"

source "${INFRA}/config.env"

if [ -f "${INFRA}/state.env" ]; then
  source "${INFRA}/state.env"
fi

DELETE_S3=false
if [[ "${1:-}" == "--delete-s3" ]]; then
  DELETE_S3=true
fi

log() { echo "[teardown] $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║               CodeGuard — Teardown                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Region  : ${AWS_REGION}"
echo "  Account : ${AWS_ACCOUNT_ID}"
echo "  Delete S3: ${DELETE_S3}"
echo ""
read -p "Type 'yes' to confirm teardown: " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# ── CloudWatch alarms ─────────────────────────────────────────────────────────
log "Deleting CloudWatch alarms..."
aws cloudwatch delete-alarms \
  --alarm-names \
    codeguard-lambda-error-rate \
    codeguard-lambda-p95-duration \
    codeguard-ec2-cpu-high \
    codeguard-scanner-error-rate \
    codeguard-notifier-error-rate \
  --region "${AWS_REGION}" 2>/dev/null || true

# ── EventBridge rules ─────────────────────────────────────────────────────────
log "Removing EventBridge targets and rules..."
for RULE in codeguard-lambda-warmup codeguard-scan-failed-retry codeguard-scanner-warmup; do
  TARGETS=$(aws events list-targets-by-rule --rule "${RULE}" --region "${AWS_REGION}" \
    --query 'Targets[].Id' --output text 2>/dev/null || echo "")
  if [ -n "${TARGETS}" ]; then
    aws events remove-targets --rule "${RULE}" --ids ${TARGETS} --region "${AWS_REGION}" 2>/dev/null || true
  fi
  aws events delete-rule --name "${RULE}" --region "${AWS_REGION}" 2>/dev/null || true
done

# ── S3 notification ───────────────────────────────────────────────────────────
log "Removing S3 event notification..."
aws s3api put-bucket-notification-configuration \
  --bucket "${S3_BUCKET_NAME}" \
  --notification-configuration '{}' \
  --region "${AWS_REGION}" 2>/dev/null || true

# ── Lambda functions ──────────────────────────────────────────────────────────
for FN in "${NOTIFIER_LAMBDA_NAME}" "${SAST_LAMBDA_NAME}" "${WEBHOOK_LAMBDA_NAME}"; do
  log "Deleting Lambda: ${FN}..."
  aws lambda delete-function --function-name "${FN}" --region "${AWS_REGION}" 2>/dev/null || true
done

# ── ECR repositories ──────────────────────────────────────────────────────────
for REPO in "${WEBHOOK_ECR_REPO}" "${SCANNER_ECR_REPO}"; do
  log "Deleting ECR repository: ${REPO}..."
  aws ecr delete-repository \
    --repository-name "${REPO}" \
    --force \
    --region "${AWS_REGION}" 2>/dev/null || true
done

# ── SNS topic ─────────────────────────────────────────────────────────────────
if [ -n "${SNS_TOPIC_ARN:-}" ]; then
  log "Deleting SNS topic: ${SNS_TOPIC_ARN}..."
  aws sns delete-topic --topic-arn "${SNS_TOPIC_ARN}" --region "${AWS_REGION}" 2>/dev/null || true
fi

# ── S3 bucket ─────────────────────────────────────────────────────────────────
if [ "${DELETE_S3}" = "true" ]; then
  log "Deleting all S3 objects and bucket: ${S3_BUCKET_NAME}..."
  aws s3 rm "s3://${S3_BUCKET_NAME}" --recursive --region "${AWS_REGION}" 2>/dev/null || true
  aws s3api delete-bucket --bucket "${S3_BUCKET_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
else
  log "S3 bucket preserved: s3://${S3_BUCKET_NAME} (pass --delete-s3 to remove)"
fi

# ── EC2 ───────────────────────────────────────────────────────────────────────
if [ -n "${EC2_INSTANCE_ID:-}" ]; then
  log "Terminating EC2 instance: ${EC2_INSTANCE_ID}..."
  aws ec2 terminate-instances --instance-ids "${EC2_INSTANCE_ID}" --region "${AWS_REGION}" 2>/dev/null || true
  aws ec2 wait instance-terminated --instance-ids "${EC2_INSTANCE_ID}" --region "${AWS_REGION}" 2>/dev/null || true
fi

if [ -n "${EC2_EIP_ALLOC_ID:-}" ]; then
  log "Releasing EC2 Elastic IP..."
  aws ec2 release-address --allocation-id "${EC2_EIP_ALLOC_ID}" --region "${AWS_REGION}" 2>/dev/null || true
fi

# ── VPC endpoints ─────────────────────────────────────────────────────────────
for EP in "${S3_ENDPOINT_ID:-}" "${SNS_ENDPOINT_ID:-}"; do
  [ -z "${EP}" ] && continue
  log "Deleting VPC endpoint: ${EP}..."
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${EP}" --region "${AWS_REGION}" 2>/dev/null || true
done

# ── NAT Gateway ───────────────────────────────────────────────────────────────
if [ -n "${NAT_GW_ID:-}" ]; then
  log "Deleting NAT Gateway: ${NAT_GW_ID}..."
  aws ec2 delete-nat-gateway --nat-gateway-id "${NAT_GW_ID}" --region "${AWS_REGION}" 2>/dev/null || true
  log "Waiting for NAT Gateway deletion..."
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids "${NAT_GW_ID}" --region "${AWS_REGION}" 2>/dev/null || true
fi

if [ -n "${NAT_EIP_ALLOC_ID:-}" ]; then
  log "Releasing NAT Elastic IP..."
  aws ec2 release-address --allocation-id "${NAT_EIP_ALLOC_ID}" --region "${AWS_REGION}" 2>/dev/null || true
fi

# ── Route tables / subnets / IGW / security groups / VPC ─────────────────────
for RT in "${PUBLIC_RT_ID:-}" "${PRIVATE_RT_ID:-}"; do
  [ -z "${RT}" ] && continue
  log "Deleting route table: ${RT}..."
  aws ec2 describe-route-tables --route-table-ids "${RT}" --region "${AWS_REGION}" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r ASSOC; do
        [ -n "${ASSOC}" ] && aws ec2 disassociate-route-table --association-id "${ASSOC}" --region "${AWS_REGION}" 2>/dev/null || true
      done
  aws ec2 delete-route-table --route-table-id "${RT}" --region "${AWS_REGION}" 2>/dev/null || true
done

for SN in "${PUBLIC_SUBNET_ID:-}" "${PRIVATE_SUBNET_ID:-}"; do
  [ -z "${SN}" ] && continue
  log "Deleting subnet: ${SN}..."
  aws ec2 delete-subnet --subnet-id "${SN}" --region "${AWS_REGION}" 2>/dev/null || true
done

if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  log "Detaching and deleting IGW: ${IGW_ID}..."
  aws ec2 detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" --region "${AWS_REGION}" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" --region "${AWS_REGION}" 2>/dev/null || true
fi

for SG in "${EC2_SG_ID:-}" "${LAMBDA_SG_ID:-}" "${SNS_ENDPOINT_SG_ID:-}"; do
  [ -z "${SG}" ] && continue
  log "Deleting security group: ${SG}..."
  aws ec2 delete-security-group --group-id "${SG}" --region "${AWS_REGION}" 2>/dev/null || true
done

if [ -n "${VPC_ID:-}" ]; then
  log "Deleting VPC: ${VPC_ID}..."
  aws ec2 delete-vpc --vpc-id "${VPC_ID}" --region "${AWS_REGION}" 2>/dev/null || true
fi

# ── Clear state file ──────────────────────────────────────────────────────────
echo "# Cleared by teardown.sh" > "${INFRA}/state.env"

log ""
log "Teardown complete."
