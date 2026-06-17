# ══════════════════════════════════════════════════════════════════════════════
#  Lambda functions
#    - webhook  : container image, in VPC
#    - scanner  : container image, in VPC
#    - notifier : zip (nodejs22.x), in VPC
# ══════════════════════════════════════════════════════════════════════════════

# ── Webhook handler ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "webhook" {
  function_name = var.webhook_lambda_name
  role          = local.lambda_role_arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.webhook.repository_url}@${data.aws_ecr_image.webhook.image_digest}"
  memory_size   = var.lambda_memory
  timeout       = var.webhook_lambda_timeout

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET_NAME       = local.s3_bucket_name
      SCAN_QUEUE_URL       = aws_sqs_queue.scan_jobs.url
      AWS_REGION_NAME      = var.aws_region
      WEBHOOK_SECRET_PARAM = var.webhook_secret_param
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.webhook.name
  }
}

# Async invocations (EventBridge, S3, cross-Lambda) retry twice on failure.
resource "aws_lambda_function_event_invoke_config" "webhook" {
  function_name          = aws_lambda_function.webhook.function_name
  maximum_retry_attempts = 2
}

# ── SAST scanner ──────────────────────────────────────────────────────────────
resource "aws_lambda_function" "scanner" {
  function_name = var.scanner_lambda_name
  role          = local.lambda_role_arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.scanner.repository_url}@${data.aws_ecr_image.scanner.image_digest}"
  memory_size   = var.lambda_memory
  timeout       = var.scanner_lambda_timeout

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET_NAME     = local.s3_bucket_name
      GITHUB_TOKEN_PARAM = var.github_token_param
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.scanner.name
  }
}

# ── Notifier (zip) ────────────────────────────────────────────────────────────
# deploy.sh runs `npm install --omit=dev` in lambda-notifier before apply so the
# node_modules are present when archive_file zips the directory.
data "archive_file" "notifier" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda-notifier"
  output_path = "${path.module}/build/notifier.zip"
}

resource "aws_lambda_function" "notifier" {
  function_name    = var.notifier_lambda_name
  role             = local.lambda_role_arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  memory_size      = var.lambda_memory
  timeout          = var.notifier_lambda_timeout

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET_NAME     = local.s3_bucket_name
      SNS_TOPIC_ARN      = aws_sns_topic.alerts.arn
      GITHUB_TOKEN_PARAM = var.github_token_param
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.notifier.name
  }
}

# ── Resource-based permissions ────────────────────────────────────────────────
# API Gateway → webhook
resource "aws_lambda_permission" "apigw_invoke_webhook" {
  statement_id  = "ApiGatewayInvokeWebhook"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*/webhook"
}

# S3 → notifier
resource "aws_lambda_permission" "s3_invoke_notifier" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.notifier.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.reports.arn
  source_account = local.account_id
}
