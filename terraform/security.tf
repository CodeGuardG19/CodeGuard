# ── Security Group: SNS interface endpoint ───────────────────────────────────
# Accepts HTTPS from the private subnet so Lambdas can reach SNS privately.
resource "aws_security_group" "sns_endpoint" {
  name        = "codeguard-sns-endpoint-sg"
  description = "Security group for SNS VPC interface endpoint"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from private subnet"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = [var.private_subnet_cidr]
  }

  tags = { Name = "codeguard-sns-endpoint-sg" }
}

# ── Security Group: Lambda (private) ─────────────────────────────────────────
# No inbound — Lambda is invoked by AWS service principals (API Gateway,
# EventBridge, S3), not over the network. Outbound HTTPS only.
resource "aws_security_group" "lambda" {
  name        = "codeguard-lambda-sg"
  description = "CodeGuard Lambda - no inbound, outbound HTTPS via NAT only"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS out (GitHub via NAT, S3/SNS via VPC endpoints)"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "codeguard-lambda-sg" }
}
