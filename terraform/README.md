# CodeGuard — Terraform

All infrastructure is defined declaratively here. The shell scripts only do what
Terraform can't (build/push container images, zip the notifier) and then call
`terraform apply` / `terraform destroy`.

## Layout

| File | Resources |
|------|-----------|
| `versions.tf`    | Terraform + AWS/archive provider versions, default `Project` tag |
| `variables.tf`   | All tunables (region, names, timeouts, SSM param names) |
| `locals.tf`      | Account ID, region, LabRole lookup, S3 bucket name |
| `vpc.tf`         | VPC, public/private subnets, IGW, NAT GW + EIP, route tables, S3 + SNS endpoints |
| `security.tf`    | Lambda SG (egress 443 only) and SNS-endpoint SG |
| `s3-sns.tf`      | Reports bucket (versioned, private), SNS topic + email sub, S3→notifier notification |
| `sqs.tf`         | Scan-job queue + DLQ, scanner event source mapping, DLQ-not-empty alarm |
| `ecr.tf`         | Two ECR repos + image-digest data sources |
| `lambda.tf`      | webhook / scanner (image) + notifier (zip) functions, permissions, retry config |
| `apigateway.tf`  | HTTP API, integration, `POST /webhook` route, `$default` stage |
| `eventbridge.tf` | Warm-up rules (webhook + scanner). Scan retries are handled by SQS + the DLQ |
| `cloudwatch.tf`  | Log groups (30-day) + four alarms |
| `outputs.tf`     | Webhook URL, bucket, topic, ECR repo URLs, SQS queue URLs |

## One-time setup

```bash
cp terraform.tfvars.example terraform.tfvars   # set notification_email
# Pre-create the secrets (Terraform never sees their values):
aws ssm put-parameter --name /codeguard/github-webhook-secret --value "<SECRET>" --type SecureString
aws ssm put-parameter --name /codeguard/github-token          --value "<PAT>"    --type SecureString
```

## Deploy / destroy

Run from the project root (the scripts cd into this directory):

```bash
./deploy.sh     # init → create ECR → build+push images → zip notifier → apply
./destroy.sh    # terraform destroy
```

## Notes vs. the old `infra/*.sh`

- **IAM**: `LabRole` is looked up by name, never created (unchanged).
- **Secrets**: still in SSM, created out of band (unchanged).
- **Notifier** now runs inside the private subnet (all three Lambdas are in the VPC).
- Account ID is now auto-detected (`aws_caller_identity`) — no need to edit it in.
- Log groups are wired into each function via `logging_config` so they actually
  collect logs (the old scripts created them but left them unused).
- Image updates are detected via ECR image digest, so re-running `deploy.sh`
  after a code change redeploys the affected Lambda.
