#!/usr/bin/env bash
# 03-s3-sns.sh — Creates the shared S3 reports bucket and SNS alerts topic.
# Run BEFORE the Lambda scripts so SNS_TOPIC_ARN is available to them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[03-s3-sns] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

# ── S3 bucket ─────────────────────────────────────────────────────────────────
log "Creating shared S3 bucket: ${S3_BUCKET_NAME}..."
if aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  log "Bucket already exists: ${S3_BUCKET_NAME}"
else
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${S3_BUCKET_NAME}" \
      --region "${AWS_REGION}"
  else
    aws s3api create-bucket \
      --bucket "${S3_BUCKET_NAME}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  fi
  log "Bucket created."
fi

# Block all public access
aws s3api put-public-access-block \
  --bucket "${S3_BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region "${AWS_REGION}"

# Enable versioning (preserves report history across scan re-runs)
aws s3api put-bucket-versioning \
  --bucket "${S3_BUCKET_NAME}" \
  --versioning-configuration Status=Enabled \
  --region "${AWS_REGION}"

aws s3api put-bucket-tagging \
  --bucket "${S3_BUCKET_NAME}" \
  --tagging "TagSet=[{Key=Project,Value=${PROJECT_TAG}}]" \
  --region "${AWS_REGION}"

log "S3 bucket ready: s3://${S3_BUCKET_NAME}"
save S3_BUCKET_NAME "${S3_BUCKET_NAME}"

# ── SNS topic ─────────────────────────────────────────────────────────────────
log "Creating SNS topic: ${SNS_TOPIC_NAME}..."
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name "${SNS_TOPIC_NAME}" \
  --region "${AWS_REGION}" \
  --query 'TopicArn' --output text)
log "SNS topic ARN: ${SNS_TOPIC_ARN}"
save SNS_TOPIC_ARN "${SNS_TOPIC_ARN}"

# Tag the topic
aws sns tag-resource \
  --resource-arn "${SNS_TOPIC_ARN}" \
  --tags "Key=Project,Value=${PROJECT_TAG}" \
  --region "${AWS_REGION}" 2>/dev/null || true

# Subscribe notification email
if [ -n "${NOTIFICATION_EMAIL}" ] && [ "${NOTIFICATION_EMAIL}" != "YOUR_EMAIL@example.com" ]; then
  log "Subscribing ${NOTIFICATION_EMAIL} to SNS topic..."
  aws sns subscribe \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --protocol email \
    --notification-endpoint "${NOTIFICATION_EMAIL}" \
    --region "${AWS_REGION}" > /dev/null
  log "Subscription pending — check ${NOTIFICATION_EMAIL} inbox to confirm."
else
  log "WARNING: NOTIFICATION_EMAIL not set in config.env — skipping email subscription."
fi

log "03-s3-sns.sh complete."
