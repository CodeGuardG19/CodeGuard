#!/usr/bin/env bash
# 08-lambda-notifier.sh — Packages and deploys the notifier Lambda (zip, nodejs22.x),
#                         then wires the S3 trigger for jobs/*/report.json events.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[08-lambda-notifier] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

NOTIFIER_DIR="${SCRIPT_DIR}/../lambda-notifier"
ZIP_PATH="/tmp/codeguard-notifier.zip"
NOTIFIER_LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${NOTIFIER_LAMBDA_NAME}"

# ── Verify SNS_TOPIC_ARN is available (set by 06-s3-sns.sh) ──────────────────
if [ -z "${SNS_TOPIC_ARN:-}" ]; then
  echo "ERROR: SNS_TOPIC_ARN not found in state.env. Run 06-s3-sns.sh first."
  exit 1
fi

# ── Install dependencies and package zip ─────────────────────────────────────
log "Installing notifier Lambda dependencies..."
(cd "${NOTIFIER_DIR}" && npm install --omit=dev --silent)

log "Creating deployment zip..."
rm -f "${ZIP_PATH}"
(cd "${NOTIFIER_DIR}" && zip -r "${ZIP_PATH}" . --exclude "*.git*" --quiet)
log "Zip created: ${ZIP_PATH}"

# ── Lambda: create or update ──────────────────────────────────────────────────
EXISTING=$(aws lambda get-function \
  --function-name "${NOTIFIER_LAMBDA_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "")

if [ -z "${EXISTING}" ]; then
  log "Creating Lambda function ${NOTIFIER_LAMBDA_NAME}..."
  aws lambda create-function \
    --function-name "${NOTIFIER_LAMBDA_NAME}" \
    --runtime nodejs22.x \
    --handler index.handler \
    --zip-file "fileb://${ZIP_PATH}" \
    --role "${LAMBDA_ROLE_ARN}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${NOTIFIER_LAMBDA_TIMEOUT}" \
    --environment "Variables={BUCKET_NAME=${S3_BUCKET_NAME},SNS_TOPIC_ARN=${SNS_TOPIC_ARN},GITHUB_TOKEN_PARAM=${GITHUB_TOKEN_PARAM}}" \
    --tags "Project=${PROJECT_TAG}" \
    --region "${AWS_REGION}"

  log "Waiting for Lambda to become active..."
  aws lambda wait function-active \
    --function-name "${NOTIFIER_LAMBDA_NAME}" \
    --region "${AWS_REGION}"
else
  log "Updating existing notifier Lambda code..."
  aws lambda update-function-code \
    --function-name "${NOTIFIER_LAMBDA_NAME}" \
    --zip-file "fileb://${ZIP_PATH}" \
    --region "${AWS_REGION}"

  aws lambda wait function-updated \
    --function-name "${NOTIFIER_LAMBDA_NAME}" \
    --region "${AWS_REGION}"

  log "Updating notifier Lambda configuration..."
  aws lambda update-function-configuration \
    --function-name "${NOTIFIER_LAMBDA_NAME}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${NOTIFIER_LAMBDA_TIMEOUT}" \
    --environment "Variables={BUCKET_NAME=${S3_BUCKET_NAME},SNS_TOPIC_ARN=${SNS_TOPIC_ARN},GITHUB_TOKEN_PARAM=${GITHUB_TOKEN_PARAM}}" \
    --region "${AWS_REGION}"

  aws lambda wait function-updated \
    --function-name "${NOTIFIER_LAMBDA_NAME}" \
    --region "${AWS_REGION}"
fi

save NOTIFIER_LAMBDA_ARN "${NOTIFIER_LAMBDA_ARN}"

# ── Grant S3 permission to invoke this Lambda ─────────────────────────────────
log "Granting S3 permission to invoke notifier Lambda..."
aws lambda add-permission \
  --function-name "${NOTIFIER_LAMBDA_NAME}" \
  --statement-id AllowS3Invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${S3_BUCKET_NAME}" \
  --source-account "${AWS_ACCOUNT_ID}" \
  --region "${AWS_REGION}" 2>/dev/null || true

# ── S3 event notification: jobs/*/report.json → notifier Lambda ───────────────
log "Configuring S3 event notification for report.json uploads..."

NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "${NOTIFIER_LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            { "Name": "prefix", "Value": "jobs/" },
            { "Name": "suffix", "Value": "report.json" }
          ]
        }
      }
    }
  ]
}
EOF
)

aws s3api put-bucket-notification-configuration \
  --bucket "${S3_BUCKET_NAME}" \
  --notification-configuration "${NOTIFICATION_CONFIG}" \
  --region "${AWS_REGION}"

log "S3 → Lambda trigger configured: s3://${S3_BUCKET_NAME}/jobs/*/report.json"

log "08-lambda-notifier.sh complete."
