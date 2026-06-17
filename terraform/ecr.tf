# ── ECR repositories for the two container-image Lambdas ─────────────────────
# deploy.sh creates these first (terraform apply -target), then builds and
# pushes the images, then runs the full apply so the data sources below can
# resolve the pushed image digests.
resource "aws_ecr_repository" "webhook" {
  name         = var.webhook_ecr_repo
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "scanner" {
  name         = var.scanner_ecr_repo
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Resolve the digest of the pushed image so Lambda redeploys whenever the
# image content changes (not just when the tag is reused).
data "aws_ecr_image" "webhook" {
  repository_name = aws_ecr_repository.webhook.name
  image_tag       = var.image_tag
}

data "aws_ecr_image" "scanner" {
  repository_name = aws_ecr_repository.scanner.name
  image_tag       = var.image_tag
}
