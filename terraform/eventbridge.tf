# ══════════════════════════════════════════════════════════════════════════════
#  EventBridge
#    - warm-up pings (every 5 min) for the webhook + scanner Lambdas
#    (Scan retries are handled by SQS visibility-timeout redelivery + the DLQ;
#     see sqs.tf. There is no longer a SCAN_FAILED rule.)
# ══════════════════════════════════════════════════════════════════════════════

# ── Warm-up: webhook handler ──────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "webhook_warmup" {
  name                = "codeguard-lambda-warmup"
  description         = "Keeps CodeGuard webhook handler Lambda warm to minimise cold starts"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "webhook_warmup" {
  rule  = aws_cloudwatch_event_rule.webhook_warmup.name
  arn   = aws_lambda_function.webhook.arn
  input = jsonencode({ source = "aws.events", "detail-type" = "warmup" })
}

resource "aws_lambda_permission" "webhook_warmup" {
  statement_id  = "AllowEventBridgeWarmup"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.webhook_warmup.arn
}

# ── Warm-up: scanner ──────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "scanner_warmup" {
  name                = "codeguard-scanner-warmup"
  description         = "Keeps CodeGuard SAST scanner Lambda warm"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "scanner_warmup" {
  rule  = aws_cloudwatch_event_rule.scanner_warmup.name
  arn   = aws_lambda_function.scanner.arn
  input = jsonencode({ source = "aws.events", "detail-type" = "warmup" })
}

resource "aws_lambda_permission" "scanner_warmup" {
  statement_id  = "AllowEventBridgeScannerWarmup"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scanner.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scanner_warmup.arn
}
