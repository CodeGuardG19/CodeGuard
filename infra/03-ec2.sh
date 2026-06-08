#!/usr/bin/env bash
# 03-ec2.sh — Launches EC2 (Amazon Linux 2023 kernel 6.1, t3.micro) in public
#             subnet, installs Nginx, configures it as a reverse proxy to Lambda
#             Function URL, and assigns an Elastic IP.
#             No SSH key pair — access is SSM Session Manager only.
#             Uses the pre-provisioned LabRole / LabInstanceProfile (course env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

STATE_FILE="${SCRIPT_DIR}/state.env"

log()  { echo "[03-ec2] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

# ── Resolve Amazon Linux 2023 kernel 6.1 AMI ─────────────────────────────────
# Pins to kernel 6.1 as required. SSM always returns the latest patch of that
# kernel line so you get security updates without changing the kernel major version.
log "Resolving Amazon Linux 2023 kernel-6.1 AMI..."
EC2_AMI_ID=$(aws ssm get-parameter \
  --name "${EC2_AMI_SSM_PATH}" \
  --region "${AWS_REGION}" \
  --query 'Parameter.Value' --output text)
log "AMI: ${EC2_AMI_ID}"
save EC2_AMI_ID "${EC2_AMI_ID}"

# ── User data: install Nginx, Certbot, configure reverse proxy ───────────────
# nginx.conf is deployed via SSM Run Command after instance is running.
# User data only installs packages and starts the service skeleton.
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail

# Update and install Nginx + Certbot
dnf update -y
dnf install -y nginx certbot python3-certbot-nginx amazon-cloudwatch-agent

# Ensure Nginx starts on boot
systemctl enable nginx

# Create web root for Certbot challenge
mkdir -p /var/www/certbot

# Placeholder nginx config will be overwritten by SSM Run Command (05-cloudwatch.sh)
# that runs after the Lambda Function URL is known.
cat > /etc/nginx/conf.d/codeguard.conf <<'NGINXCONF'
server {
    listen 80;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 503 "CodeGuard not yet configured";
    }
}
NGINXCONF

systemctl start nginx

# Signal CloudFormation/user-data success
echo "EC2 user-data complete" >> /var/log/codeguard-init.log
USERDATA
)

# ── Launch EC2 instance ───────────────────────────────────────────────────────
# Uses LabInstanceProfile — the pre-provisioned course role that already has
# SSM Session Manager and CloudWatch Agent permissions attached.
log "Launching EC2 instance (${EC2_INSTANCE_TYPE}, AL2023 kernel 6.1)..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "${EC2_AMI_ID}" \
  --instance-type "${EC2_INSTANCE_TYPE}" \
  --subnet-id "${PUBLIC_SUBNET_ID}" \
  --security-group-ids "${EC2_SG_ID}" \
  --iam-instance-profile Name="${LAB_INSTANCE_PROFILE}" \
  --user-data "${USER_DATA}" \
  --no-associate-public-ip-address \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=codeguard-ec2},{Key=Project,Value=${PROJECT_TAG}}]" \
  --region "${AWS_REGION}" \
  --query 'Instances[0].InstanceId' --output text)

log "Waiting for instance to enter running state..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
log "Instance running: ${INSTANCE_ID}"
save EC2_INSTANCE_ID "${INSTANCE_ID}"

# ── Elastic IP ────────────────────────────────────────────────────────────────
log "Allocating Elastic IP for EC2..."
EC2_EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --region "${AWS_REGION}" \
  --query 'AllocationId' --output text)
aws ec2 create-tags --resources "${EC2_EIP_ALLOC_ID}" --tags \
  Key=Name,Value=codeguard-ec2-eip \
  Key=Project,Value="${PROJECT_TAG}" 2>/dev/null || true

aws ec2 associate-address \
  --instance-id "${INSTANCE_ID}" \
  --allocation-id "${EC2_EIP_ALLOC_ID}"

EC2_PUBLIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "${EC2_EIP_ALLOC_ID}" \
  --query 'Addresses[0].PublicIp' --output text)

log "Elastic IP: ${EC2_PUBLIC_IP} (allocation: ${EC2_EIP_ALLOC_ID})"
save EC2_EIP_ALLOC_ID "${EC2_EIP_ALLOC_ID}"
save EC2_PUBLIC_IP "${EC2_PUBLIC_IP}"

# ── Deploy nginx.conf via SSM Run Command ─────────────────────────────────────
# Wait for SSM agent to be ready before sending commands
log "Waiting for SSM agent on instance..."
for i in $(seq 1 30); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  if [ "${STATUS}" = "Online" ]; then
    log "SSM agent is online."
    break
  fi
  log "SSM not ready (attempt ${i}/30), waiting 10s..."
  sleep 10
done

NGINX_CONF=$(cat "${SCRIPT_DIR}/../ec2/nginx.conf")

SSM_CMD_ID=$(aws ssm send-command \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    \"cat > /etc/nginx/conf.d/codeguard.conf << 'NGINXEOF'\n${NGINX_CONF}\nNGINXEOF\",
    \"nginx -t && systemctl reload nginx\"
  ]" \
  --region "${AWS_REGION}" \
  --query 'Command.CommandId' --output text)

log "Waiting for SSM command ${SSM_CMD_ID} to complete..."
aws ssm wait command-executed \
  --command-id "${SSM_CMD_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --region "${AWS_REGION}" 2>/dev/null || true

log "Nginx configuration deployed."
log ""
log "╔═══════════════════════════════════════════════════════════════╗"
log "║  EC2 Elastic IP: ${EC2_PUBLIC_IP}                            ║"
log "║  Next step: after 04-lambda.sh runs and you have a domain,   ║"
log "║  run certbot to issue a TLS cert:                             ║"
log "║    sudo certbot --nginx -d your.domain.com                    ║"
log "╚═══════════════════════════════════════════════════════════════╝"

log "03-ec2.sh complete."
