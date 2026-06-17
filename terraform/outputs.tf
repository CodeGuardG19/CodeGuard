output "webhook_url" {
  description = "Public HTTPS endpoint to configure as the GitHub webhook payload URL"
  value       = "${aws_apigatewayv2_api.webhook.api_endpoint}/webhook"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.reports.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "scan_queue_url" {
  value = aws_sqs_queue.scan_jobs.url
}

output "scan_dlq_url" {
  value = aws_sqs_queue.scan_dlq.url
}

output "webhook_ecr_repo_url" {
  value = aws_ecr_repository.webhook.repository_url
}

output "scanner_ecr_repo_url" {
  value = aws_ecr_repository.scanner.repository_url
}
