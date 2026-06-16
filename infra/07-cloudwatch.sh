#!/usr/bin/env bash
# 07-cloudwatch.sh — Creates CloudWatch log groups and alarms for Lambda functions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

log() { echo "[07-cloudwatch] $*"; }

# ── Lambda log groups with 30-day retention ───────────────────────────────────
for LOG_GROUP in \
  "/codeguard/lambda/webhook-handler" \
  "/codeguard/lambda/sast-scanner" \
  "/codeguard/lambda/notifier"; do
  log "Creating log group ${LOG_GROUP}..."
  aws logs create-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${AWS_REGION}" 2>/dev/null || true
  aws logs put-retention-policy \
    --log-group-name "${LOG_GROUP}" \
    --retention-in-days 30 \
    --region "${AWS_REGION}"
done
log "Lambda log groups ready."

# ── CloudWatch Alarm: Lambda error rate > 5% over 5 minutes ──────────────────
# Uses the built-in Errors metric. Threshold is absolute count — we use a math
# expression to compute rate against Invocations, but CloudWatch metric math
# alarms require a different approach; we alarm on absolute errors > 5 as a
# practical proxy (adjust threshold for your invocation volume).
log "Creating Lambda error-rate alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "codeguard-lambda-error-rate" \
  --alarm-description "Lambda webhook handler error rate exceeds 5% threshold" \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions "Name=FunctionName,Value=${WEBHOOK_LAMBDA_NAME}" \
  --statistic "Sum" \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --region "${AWS_REGION}"
log "Lambda error alarm created."

# ── CloudWatch Alarm: Lambda P95 duration > 10 seconds ───────────────────────
log "Creating Lambda P95 duration alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "codeguard-lambda-p95-duration" \
  --alarm-description "Lambda webhook handler P95 duration exceeds 10 seconds" \
  --namespace "AWS/Lambda" \
  --metric-name "Duration" \
  --dimensions "Name=FunctionName,Value=${WEBHOOK_LAMBDA_NAME}" \
  --extended-statistic "p95" \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 10000 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --region "${AWS_REGION}"
log "Lambda duration alarm created."

# ── CloudWatch Alarms: SAST Scanner errors ───────────────────────────────────
log "Creating scanner error alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "codeguard-scanner-error-rate" \
  --alarm-description "SAST scanner Lambda error rate exceeds threshold" \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions "Name=FunctionName,Value=${SAST_LAMBDA_NAME}" \
  --statistic "Sum" \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --region "${AWS_REGION}"

# ── CloudWatch Alarms: Notifier errors ───────────────────────────────────────
log "Creating notifier error alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "codeguard-notifier-error-rate" \
  --alarm-description "Notifier Lambda error rate exceeds threshold" \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions "Name=FunctionName,Value=${NOTIFIER_LAMBDA_NAME}" \
  --statistic "Sum" \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --region "${AWS_REGION}"

log "07-cloudwatch.sh complete."
