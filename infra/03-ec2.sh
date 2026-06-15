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
exec >> /var/log/codeguard-init.log 2>&1

echo "[$(date)] user-data starting"

# ── Install packages ───────────────────────────────────────────────────────────
dnf update -y
dnf install -y nginx amazon-cloudwatch-agent nodejs npm

systemctl enable nginx
mkdir -p /var/www/certbot

# ── Nginx: proxy /webhook to the local proxy process on :3001 ─────────────────
# No placeholder needed — nginx is fully configured from the start.
cat > /etc/nginx/conf.d/codeguard.conf <<'NGINXEOF'
limit_req_zone $binary_remote_addr zone=webhook_limit:10m rate=20r/s;

server {
    listen 80;
    client_max_body_size 26m;
    access_log /var/log/nginx/access.log combined;
    error_log  /var/log/nginx/error.log warn;

    location = /webhook {
        limit_except POST { deny all; }
        limit_req zone=webhook_limit burst=5 nodelay;
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass_request_headers on;
        proxy_read_timeout    10s;
        proxy_connect_timeout  5s;
        proxy_send_timeout     5s;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / { return 404; }
}
NGINXEOF

systemctl start nginx

# ── Webhook proxy: invokes Lambda directly using EC2 instance role (LabRole) ──
# Lambda Function URLs require public IAM auth that Academy SCPs block.
# Direct lambda:InvokeFunction from LabRole has no such restriction.
mkdir -p /opt/codeguard-proxy
cd /opt/codeguard-proxy
npm init -y >> /var/log/codeguard-init.log 2>&1
npm install @aws-sdk/client-lambda --omit=dev >> /var/log/codeguard-init.log 2>&1

cat > /opt/codeguard-proxy/index.js <<'PROXYEOF'
'use strict';
const http = require('http');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');

const REGION = 'us-east-1';
const FUNCTION_NAME = 'codeguard-webhook-handler';
const lambda = new LambdaClient({ region: REGION });

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/webhook') {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end('{"error":"not found"}');
    return;
  }

  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');

    // Build Function URL-compatible event so Lambda handler needs no changes
    const event = {
      version: '2.0',
      routeKey: '$default',
      rawPath: '/webhook',
      rawQueryString: '',
      headers: Object.fromEntries(Object.entries(req.headers)),
      body,
      isBase64Encoded: false,
      requestContext: { http: { method: 'POST', path: '/webhook' } },
    };

    // GitHub only needs a 2xx — respond immediately, invoke Lambda async
    res.writeHead(202, { 'Content-Type': 'application/json' });
    res.end('{"status":"accepted"}');

    lambda.send(new InvokeCommand({
      FunctionName: FUNCTION_NAME,
      InvocationType: 'Event',
      Payload: Buffer.from(JSON.stringify(event)),
    })).then(() => {
      console.log('[proxy] Lambda invoked OK');
    }).catch(err => {
      console.error('[proxy] Lambda invoke failed:', err.message);
    });
  });

  req.on('error', err => {
    console.error('[proxy] request error:', err.message);
    if (!res.headersSent) { res.writeHead(400); res.end(); }
  });
});

server.listen(3001, '127.0.0.1', () => {
  console.log('[proxy] CodeGuard webhook proxy listening on :3001');
});
PROXYEOF

# ── Systemd service for proxy ──────────────────────────────────────────────────
cat > /etc/systemd/system/codeguard-proxy.service <<'SERVICEEOF'
[Unit]
Description=CodeGuard Webhook Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/codeguard-proxy
ExecStart=/usr/bin/node /opt/codeguard-proxy/index.js
Restart=always
RestartSec=5
Environment=AWS_REGION=us-east-1
Environment=LAMBDA_FUNCTION_NAME=codeguard-webhook-handler
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable codeguard-proxy
systemctl start codeguard-proxy

echo "[$(date)] user-data complete."
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

# ── Wait for SSM agent to come online ─────────────────────────────────────────
# nginx will be configured by 04-lambda.sh once the Lambda Function URL is known.
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

log ""
log "╔═══════════════════════════════════════════════════════════════╗"
log "║  EC2 Elastic IP: ${EC2_PUBLIC_IP}                            ║"
log "║  Nginx is serving HTTP on port 80.                           ║"
log "║  Run 04-lambda.sh next — it will configure nginx with the    ║"
log "║  Lambda Function URL automatically via SSM send-command.     ║"
log "╚═══════════════════════════════════════════════════════════════╝"

log "03-ec2.sh complete."
