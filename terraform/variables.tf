# ── AWS Core ──────────────────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_tag" {
  description = "Value applied to the Project tag on every resource"
  type        = string
  default     = "codeguard"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

# ── IAM (Lab environment) ───────────────────────────────────────────────────────
# LabRole is pre-provisioned by the AWS Academy / course environment and is
# looked up by name — no IAM is created or modified by this Terraform config.
variable "lab_role_name" {
  description = "Name of the pre-provisioned execution role used by all Lambdas"
  type        = string
  default     = "LabRole"
}

# ── Lambda — shared ───────────────────────────────────────────────────────────
variable "lambda_memory" {
  type    = number
  default = 512
}

variable "webhook_lambda_timeout" {
  type    = number
  default = 30
}

variable "scanner_lambda_timeout" {
  type    = number
  default = 300
}

variable "notifier_lambda_timeout" {
  type    = number
  default = 30
}

# ── Lambda / ECR — names ──────────────────────────────────────────────────────
variable "webhook_lambda_name" {
  type    = string
  default = "codeguard-webhook-handler"
}

variable "scanner_lambda_name" {
  type    = string
  default = "codeguard-sast-scanner"
}

variable "notifier_lambda_name" {
  type    = string
  default = "codeguard-notifier"
}

variable "webhook_ecr_repo" {
  type    = string
  default = "codeguard-webhook-handler"
}

variable "scanner_ecr_repo" {
  type    = string
  default = "codeguard-sast-scanner"
}

variable "image_tag" {
  description = "Container image tag that deploy.sh builds and pushes to ECR"
  type        = string
  default     = "latest"
}

# ── SNS ───────────────────────────────────────────────────────────────────────
variable "sns_topic_name" {
  type    = string
  default = "codeguard-alerts"
}

variable "notification_email" {
  description = "Email address subscribed to the SNS alerts topic"
  type        = string
}

# ── SSM Parameter Store ─────────────────────────────────────────────────────────
# These parameters hold secrets and are created manually (out of band) before
# deploying. Terraform only passes their NAMES to the Lambdas as env vars; the
# functions read the secret values at runtime. Terraform never sees the secrets.
variable "webhook_secret_param" {
  type    = string
  default = "/codeguard/github-webhook-secret"
}

variable "github_token_param" {
  type    = string
  default = "/codeguard/github-token"
}
