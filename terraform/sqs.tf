# ══════════════════════════════════════════════════════════════════════════════
#  SQS — scan-job queue + dead-letter queue
#    The webhook handler enqueues a job; the scanner consumes it via an event
#    source mapping. SQS's visibility-timeout redelivery + DLQ replace the old
#    fire-and-forget Lambda invoke and the hand-rolled EventBridge retry loop.
# ══════════════════════════════════════════════════════════════════════════════

# ── Dead-letter queue ─────────────────────────────────────────────────────────
# Jobs that fail maxReceiveCount times land here for post-mortem inspection.
resource "aws_sqs_queue" "scan_dlq" {
  name                      = "codeguard-scan-dlq"
  message_retention_seconds = 1209600 # 14 days (max) — keep failures around to debug

  tags = { Name = "codeguard-scan-dlq" }
}

# ── Main scan-job queue ───────────────────────────────────────────────────────
resource "aws_sqs_queue" "scan_jobs" {
  name = "codeguard-scan-jobs"

  # Must be >= the scanner's function timeout; AWS recommends ~6x so a slow scan
  # is never redelivered while still running. scanner_lambda_timeout = 300s.
  visibility_timeout_seconds = 1800
  message_retention_seconds  = 86400 # 1 day

  # After 3 failed receives, move the message to the DLQ instead of looping forever.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.scan_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "codeguard-scan-jobs" }
}

# ── Scanner consumes the queue ────────────────────────────────────────────────
# The Lambda service polls SQS on our behalf, so this needs no VPC connectivity
# even though the scanner runs in the private subnet.
resource "aws_lambda_event_source_mapping" "scanner_sqs" {
  event_source_arn = aws_sqs_queue.scan_jobs.arn
  function_name    = aws_lambda_function.scanner.arn
  batch_size       = 1 # one scan per invocation; a failure only retries that job
  enabled          = true
}

# ── Alarm: anything in the DLQ means a scan failed 3x ──────────────────────────
# Replaces the PERMANENTLY_FAILED SNS publish the webhook used to send by hand.
resource "aws_cloudwatch_metric_alarm" "scan_dlq_not_empty" {
  alarm_name          = "codeguard-scan-dlq-not-empty"
  alarm_description   = "A scan job failed 3 times and landed in the DLQ — needs investigation"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.scan_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
