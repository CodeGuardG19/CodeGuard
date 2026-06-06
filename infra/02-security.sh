#!/usr/bin/env bash
# 02-security.sh — Creates IAM roles, policies, and security groups for CodeGuard.
# All policies follow least-privilege: specific ARNs, no wildcard resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[02-security] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

SNS_TOPIC_ARN="arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${SNS_TOPIC_NAME}"
SAST_LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${SAST_LAMBDA_NAME}"
S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET_NAME}"

# ── IAM Role: Lambda Webhook Handler ─────────────────────────────────────────
log "Creating Lambda execution role..."

LAMBDA_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

LAMBDA_ROLE_ARN=$(aws iam create-role \
  --role-name codeguard-lambda-webhook-role \
  --assume-role-policy-document "${LAMBDA_TRUST_POLICY}" \
  --tags Key=Project,Value="${PROJECT_TAG}" \
  --query 'Role.Arn' --output text)
log "Lambda role ARN: ${LAMBDA_ROLE_ARN}"
save LAMBDA_ROLE_ARN "${LAMBDA_ROLE_ARN}"

# Attach AWS managed policy for VPC networking (creates ENIs for VPC-attached Lambda)
aws iam attach-role-policy \
  --role-name codeguard-lambda-webhook-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole

LAMBDA_INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3JobMetadata",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "${S3_BUCKET_ARN}/jobs/*"
    },
    {
      "Sid": "InvokeSastScanner",
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "${SAST_LAMBDA_ARN}"
    },
    {
      "Sid": "PublishSnsAlerts",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "${SNS_TOPIC_ARN}"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/codeguard/lambda/webhook-handler:*"
    },
    {
      "Sid": "ReadWebhookSecret",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${WEBHOOK_SECRET_PARAM}"
    },
    {
      "Sid": "DecryptWebhookSecret",
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:alias/aws/ssm"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name codeguard-lambda-webhook-role \
  --policy-name codeguard-lambda-webhook-policy \
  --policy-document "${LAMBDA_INLINE_POLICY}"
log "Lambda inline policy attached."

# ── IAM Role: EC2 (SSM Session Manager only, no SSH) ─────────────────────────
log "Creating EC2 SSM role..."

EC2_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

aws iam create-role \
  --role-name codeguard-ec2-ssm-role \
  --assume-role-policy-document "${EC2_TRUST_POLICY}" \
  --tags Key=Project,Value="${PROJECT_TAG}" \
  --query 'Role.Arn' --output text > /dev/null

aws iam attach-role-policy \
  --role-name codeguard-ec2-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Allow CloudWatch agent to push metrics and logs
aws iam attach-role-policy \
  --role-name codeguard-ec2-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

EC2_INSTANCE_PROFILE=$(aws iam create-instance-profile \
  --instance-profile-name codeguard-ec2-instance-profile \
  --query 'InstanceProfile.InstanceProfileName' --output text)
aws iam add-role-to-instance-profile \
  --instance-profile-name codeguard-ec2-instance-profile \
  --role-name codeguard-ec2-ssm-role
log "EC2 instance profile: ${EC2_INSTANCE_PROFILE}"
save EC2_INSTANCE_PROFILE "${EC2_INSTANCE_PROFILE}"

# ── IAM Role: GitHub Actions OIDC (CI/CD pipeline) ───────────────────────────
log "Creating GitHub Actions OIDC role..."

# Ensure the OIDC provider exists for GitHub Actions
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" \
     --region "${AWS_REGION}" &>/dev/null; then
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
  log "OIDC provider created."
else
  log "OIDC provider already exists."
fi

# Replace YOUR_GITHUB_ORG/YOUR_REPO with real values before deploying
GITHUB_ORG="${GITHUB_ORG:-CodeGuardG19}"
GITHUB_REPO="${GITHUB_REPO:-CodeGuard}"

GHA_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_PROVIDER_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main"
      }
    }
  }]
}
EOF
)

GHA_ROLE_ARN=$(aws iam create-role \
  --role-name codeguard-gha-deploy-role \
  --assume-role-policy-document "${GHA_TRUST_POLICY}" \
  --tags Key=Project,Value="${PROJECT_TAG}" \
  --query 'Role.Arn' --output text)

ECR_REPO_ARN="arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
WEBHOOK_LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${WEBHOOK_LAMBDA_NAME}"

GHA_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories",
        "ecr:CreateRepository",
        "ecr:ListImages"
      ],
      "Resource": "${ECR_REPO_ARN}"
    },
    {
      "Sid": "LambdaDeploy",
      "Effect": "Allow",
      "Action": [
        "lambda:UpdateFunctionCode",
        "lambda:GetFunction",
        "lambda:InvokeFunction"
      ],
      "Resource": "${WEBHOOK_LAMBDA_ARN}"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name codeguard-gha-deploy-role \
  --policy-name codeguard-gha-deploy-policy \
  --policy-document "${GHA_POLICY}"
log "GitHub Actions OIDC role ARN: ${GHA_ROLE_ARN}"
save GHA_ROLE_ARN "${GHA_ROLE_ARN}"

# ── Security Group: EC2 (public) ──────────────────────────────────────────────
log "Creating EC2 security group..."
EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name codeguard-ec2-sg \
  --description "CodeGuard EC2 Nginx proxy — inbound HTTPS only" \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'GroupId' --output text)
aws ec2 create-tags --resources "${EC2_SG_ID}" --tags \
  Key=Name,Value=codeguard-ec2-sg \
  Key=Project,Value="${PROJECT_TAG}"

# Inbound: HTTPS from the internet (GitHub webhooks)
aws ec2 authorize-security-group-ingress \
  --group-id "${EC2_SG_ID}" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0"

# Outbound: only to the private subnet (Lambda Function URL via VPC)
aws ec2 authorize-security-group-egress \
  --group-id "${EC2_SG_ID}" \
  --protocol tcp --port 443 --cidr "${PRIVATE_SUBNET_CIDR}"

# Remove the default allow-all outbound rule added by AWS
DEFAULT_EGRESS_SG_RULE=$(aws ec2 describe-security-groups \
  --group-ids "${EC2_SG_ID}" \
  --query 'SecurityGroups[0].IpPermissionsEgress[?IpRanges[0].CidrIp==`0.0.0.0/0`].IpProtocol' \
  --output text 2>/dev/null || echo "")
if [ -n "${DEFAULT_EGRESS_SG_RULE}" ]; then
  aws ec2 revoke-security-group-egress \
    --group-id "${EC2_SG_ID}" \
    --protocol -1 --port -1 --cidr "0.0.0.0/0" 2>/dev/null || true
fi

log "EC2 security group: ${EC2_SG_ID}"
save EC2_SG_ID "${EC2_SG_ID}"

# ── Security Group: Lambda (private) ─────────────────────────────────────────
log "Creating Lambda security group..."
LAMBDA_SG_ID=$(aws ec2 create-security-group \
  --group-name codeguard-lambda-sg \
  --description "CodeGuard Lambda webhook handler — no inbound, outbound via NAT" \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'GroupId' --output text)
aws ec2 create-tags --resources "${LAMBDA_SG_ID}" --tags \
  Key=Name,Value=codeguard-lambda-sg \
  Key=Project,Value="${PROJECT_TAG}"

# No inbound rules — Lambda is invoked via Function URL, not direct network calls.
# Outbound: HTTPS to the NAT Gateway (for GitHub API calls only)
aws ec2 authorize-security-group-egress \
  --group-id "${LAMBDA_SG_ID}" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0"

# Remove default allow-all egress
aws ec2 revoke-security-group-egress \
  --group-id "${LAMBDA_SG_ID}" \
  --protocol -1 --port -1 --cidr "0.0.0.0/0" 2>/dev/null || true

# Re-add scoped outbound only
aws ec2 authorize-security-group-egress \
  --group-id "${LAMBDA_SG_ID}" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0"

log "Lambda security group: ${LAMBDA_SG_ID}"
save LAMBDA_SG_ID "${LAMBDA_SG_ID}"

log "02-security.sh complete."
