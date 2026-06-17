#!/usr/bin/env bash
# destroy.sh — Thin wrapper: destroy everything Terraform created.
#
# Terraform tracks the dependency graph, so a single destroy removes resources
# in the correct order (Lambdas before subnets, NAT before EIP, etc.) — no
# hand-written ordering needed. ECR repos use force_delete, so pushed images
# are removed with them.
#
# NOT touched (created out of band, same as deploy):
#   - The LabRole IAM role (course-managed)
#   - SSM parameters /codeguard/github-webhook-secret and /codeguard/github-token
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}/terraform"

echo "▶ terraform destroy"
terraform destroy -input=false -auto-approve

echo "✓ Teardown complete. All CodeGuard resources destroyed."
