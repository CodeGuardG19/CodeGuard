#!/usr/bin/env bash
# deploy.sh — Thin wrapper around Terraform for CodeGuard.
#
# All infrastructure lives in terraform/*.tf. This script only does the work
# Terraform can't: build & push the Lambda container images and zip the
# notifier, then hand everything to `terraform apply`.
#
# PREREQUISITES (once):
#   1. AWS CLI v2 authenticated (aws configure / Lab credentials) and Docker running
#   2. Terraform >= 1.5 installed
#   3. cp terraform/terraform.tfvars.example terraform/terraform.tfvars
#      and set notification_email
#   4. Pre-create the two SSM SecureString parameters (Terraform never sees these):
#        aws ssm put-parameter --name /codeguard/github-webhook-secret \
#          --value "<WEBHOOK_SECRET>" --type SecureString --region us-east-1
#        aws ssm put-parameter --name /codeguard/github-token \
#          --value "<GITHUB_PAT>"     --type SecureString --region us-east-1
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
cd "${TF_DIR}"

IMAGE_TAG="latest"

echo "▶ terraform init"
terraform init -input=false

# 1. Create ECR repos first so we have somewhere to push the images.
echo "▶ terraform apply (ECR repositories only)"
terraform apply -input=false -auto-approve \
  -target=aws_ecr_repository.webhook \
  -target=aws_ecr_repository.scanner

WEBHOOK_REPO="$(terraform output -raw webhook_ecr_repo_url)"
SCANNER_REPO="$(terraform output -raw scanner_ecr_repo_url)"
REGISTRY="${WEBHOOK_REPO%%/*}"
# Derive the region from the registry host (<acct>.dkr.ecr.<region>.amazonaws.com)
# so the ECR login token always matches the region Terraform deployed to —
# independent of whatever `aws configure` default region is set locally.
REGION="$(echo "${REGISTRY}" | cut -d. -f4)"

# 2. Build & push the two container images.
echo "▶ docker login ${REGISTRY}"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "▶ build & push webhook image"
docker build --platform linux/amd64 --provenance=false \
  -t "${WEBHOOK_REPO}:${IMAGE_TAG}" "${ROOT_DIR}/lambda-webhook"
docker push "${WEBHOOK_REPO}:${IMAGE_TAG}"

echo "▶ build & push scanner image"
docker build --platform linux/amd64 --provenance=false \
  -t "${SCANNER_REPO}:${IMAGE_TAG}" "${ROOT_DIR}/lambda-scanner"
docker push "${SCANNER_REPO}:${IMAGE_TAG}"

# 3. Install notifier deps so archive_file zips a complete bundle.
echo "▶ npm install (notifier)"
(cd "${ROOT_DIR}/lambda-notifier" && npm install --omit=dev --silent)

# 4. Apply everything.
echo "▶ terraform apply (full stack)"
terraform apply -input=false -auto-approve

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Deployment complete."
echo "   Webhook URL : $(terraform output -raw webhook_url)"
echo "   S3 bucket   : $(terraform output -raw s3_bucket_name)"
echo "   SNS topic   : $(terraform output -raw sns_topic_arn)"
echo ""
echo " Configure the GitHub webhook (Settings → Webhooks):"
echo "   Payload URL  : <webhook URL above>"
echo "   Content type : application/json"
echo "   Secret       : value stored in SSM /codeguard/github-webhook-secret"
echo "   Events       : Pull requests"
echo ""
echo " NOTE: confirm the SNS email subscription in your inbox to receive alerts."
echo "════════════════════════════════════════════════════════════════"
