#!/usr/bin/env bash
# 02-security.sh — Creates security groups for CodeGuard.
#
# IAM NOTES (Lab environment):
#   LabRole and LabInstanceProfile are pre-provisioned by the AWS Academy /
#   course environment and cannot be created or modified by student scripts.
#   This script does NOT touch IAM — it simply saves the known role ARN into
#   state.env so later scripts can reference it, then creates security groups.
#
#   If you are running in a real AWS account (not a Lab), you will need to
#   create IAM roles separately and set LAB_ROLE_ARN in config.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[02-security] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

# ── IAM: save pre-existing LabRole ARN for use by the Lambda scripts ──────────
log "Using pre-provisioned LabRole (no IAM creation in Lab environment)..."
save LAMBDA_ROLE_ARN "${LAB_ROLE_ARN}"
log "LAMBDA_ROLE_ARN=${LAB_ROLE_ARN}"

# ── Security Group: Lambda (private) ─────────────────────────────────────────
log "Creating Lambda security group..."
LAMBDA_SG_ID=$(aws ec2 create-security-group \
  --group-name codeguard-lambda-sg \
  --description "CodeGuard Lambda webhook handler - no inbound, outbound via NAT only" \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'GroupId' --output text)
aws ec2 create-tags --resources "${LAMBDA_SG_ID}" --tags \
  Key=Name,Value=codeguard-lambda-sg \
  Key=Project,Value="${PROJECT_TAG}"

# No inbound rules — Lambda is invoked via API Gateway (event-based), not raw TCP.
# Outbound: HTTPS only (via NAT Gateway → GitHub API, and via VPC endpoints → S3/SNS)
aws ec2 authorize-security-group-egress \
  --group-id "${LAMBDA_SG_ID}" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0"

# Remove the default allow-all egress, then re-add only HTTPS
aws ec2 revoke-security-group-egress \
  --group-id "${LAMBDA_SG_ID}" \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
  2>/dev/null || true

# Re-add the scoped HTTPS-only egress (revoke above may have removed it too)
aws ec2 authorize-security-group-egress \
  --group-id "${LAMBDA_SG_ID}" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0" 2>/dev/null || true

log "Lambda security group: ${LAMBDA_SG_ID}"
save LAMBDA_SG_ID "${LAMBDA_SG_ID}"

log "02-security.sh complete. (IAM skipped — using pre-provisioned LabRole)"
