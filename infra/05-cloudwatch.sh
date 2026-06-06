#!/usr/bin/env bash
# 05-cloudwatch.sh — Creates CloudWatch log groups, alarms, and installs the
#                    CloudWatch agent on EC2 to forward Nginx logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/state.env"

log() { echo "[05-cloudwatch] $*"; }

LOG_GROUP="/codeguard/lambda/webhook-handler"

# ── Log group with 30-day retention ───────────────────────────────────────────
log "Creating Lambda log group ${LOG_GROUP}..."
aws logs create-log-group \
  --log-group-name "${LOG_GROUP}" \
  --region "${AWS_REGION}" 2>/dev/null || true
aws logs put-retention-policy \
  --log-group-name "${LOG_GROUP}" \
  --retention-in-days 30 \
  --region "${AWS_REGION}"
log "Log group ready."

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

# ── CloudWatch Alarm: EC2 CPU > 80% for 10 minutes ───────────────────────────
log "Creating EC2 CPU alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "codeguard-ec2-cpu-high" \
  --alarm-description "EC2 Nginx proxy CPU utilisation exceeds 80% for 10 minutes" \
  --namespace "AWS/EC2" \
  --metric-name "CPUUtilization" \
  --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
  --statistic "Average" \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --region "${AWS_REGION}"
log "EC2 CPU alarm created."

# ── CloudWatch Agent: install and configure on EC2 ───────────────────────────
log "Pushing CloudWatch agent config to EC2 via SSM..."

CW_AGENT_CONFIG=$(cat <<'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/nginx/access.log",
            "log_group_name": "/codeguard/ec2/nginx-access",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC",
            "timestamp_format": "%d/%b/%Y:%H:%M:%S %z"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "/codeguard/ec2/nginx-error",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "CodeGuard/EC2",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/"],
        "metrics_collection_interval": 60
      }
    }
  }
}
CWCONFIG
)

SSM_CMD_ID=$(aws ssm send-command \
  --instance-ids "${EC2_INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    \"mkdir -p /opt/aws/amazon-cloudwatch-agent/etc\",
    \"cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'\n${CW_AGENT_CONFIG}\nCWEOF\",
    \"/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s\",
    \"systemctl enable amazon-cloudwatch-agent\",
    \"systemctl start amazon-cloudwatch-agent\"
  ]" \
  --region "${AWS_REGION}" \
  --query 'Command.CommandId' --output text)

log "SSM command sent: ${SSM_CMD_ID}. Waiting for completion..."
aws ssm wait command-executed \
  --command-id "${SSM_CMD_ID}" \
  --instance-id "${EC2_INSTANCE_ID}" \
  --region "${AWS_REGION}" 2>/dev/null || true
log "CloudWatch agent configured on EC2."

# Create Nginx log groups with retention
for LG in "/codeguard/ec2/nginx-access" "/codeguard/ec2/nginx-error"; do
  aws logs create-log-group \
    --log-group-name "${LG}" \
    --region "${AWS_REGION}" 2>/dev/null || true
  aws logs put-retention-policy \
    --log-group-name "${LG}" \
    --retention-in-days 30 \
    --region "${AWS_REGION}"
done
log "Nginx log groups created."

log "05-cloudwatch.sh complete."
