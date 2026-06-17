data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Pre-provisioned course role — looked up, never created.
data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  region          = data.aws_region.current.name
  lambda_role_arn = data.aws_iam_role.lab.arn

  # Single shared reports bucket for all three Lambdas.
  s3_bucket_name = "codeguard-reports-${local.account_id}"
}
