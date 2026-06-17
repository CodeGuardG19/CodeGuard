# ── S3: shared reports bucket ─────────────────────────────────────────────────
resource "aws_s3_bucket" "reports" {
  bucket = local.s3_bucket_name
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── SNS: alerts topic + email subscription ────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = var.sns_topic_name
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ── S3 → Notifier event notification ──────────────────────────────────────────
# Fires the notifier whenever a report.json lands under jobs/.
resource "aws_s3_bucket_notification" "report_created" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.notifier.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "jobs/"
    filter_suffix       = "report.json"
  }

  depends_on = [aws_lambda_permission.s3_invoke_notifier]
}
