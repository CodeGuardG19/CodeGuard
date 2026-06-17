# ── Log groups (30-day retention) ─────────────────────────────────────────────
# Wired into each function via logging_config so they actually receive logs.
resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/codeguard/lambda/webhook-handler"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "scanner" {
  name              = "/codeguard/lambda/sast-scanner"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/codeguard/lambda/notifier"
  retention_in_days = 30
}

# ── Alarms ────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "webhook_errors" {
  alarm_name          = "codeguard-lambda-error-rate"
  alarm_description   = "Lambda webhook handler error rate exceeds 5% threshold"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.webhook_lambda_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "webhook_p95_duration" {
  alarm_name          = "codeguard-lambda-p95-duration"
  alarm_description   = "Lambda webhook handler P95 duration exceeds 10 seconds"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = var.webhook_lambda_name }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10000
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "scanner_errors" {
  alarm_name          = "codeguard-scanner-error-rate"
  alarm_description   = "SAST scanner Lambda error rate exceeds threshold"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.scanner_lambda_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "notifier_errors" {
  alarm_name          = "codeguard-notifier-error-rate"
  alarm_description   = "Notifier Lambda error rate exceeds threshold"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.notifier_lambda_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}
