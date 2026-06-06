#!/usr/bin/env bash
# 01-vpc.sh — Creates VPC, subnets, IGW, NAT Gateway, route tables, and VPC endpoints.
# All resource IDs are saved to infra/state.env for use by subsequent scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

STATE_FILE="${SCRIPT_DIR}/state.env"
touch "${STATE_FILE}"

log()  { echo "[01-vpc] $*"; }
save() { echo "export $1=\"$2\"" >> "${STATE_FILE}"; }

# ── VPC ───────────────────────────────────────────────────────────────────────
log "Creating VPC (${VPC_CIDR})..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "${VPC_CIDR}" \
  --region "${AWS_REGION}" \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames
aws ec2 create-tags --resources "${VPC_ID}" --tags \
  Key=Name,Value=codeguard-vpc \
  Key=Project,Value="${PROJECT_TAG}"
log "VPC created: ${VPC_ID}"
save VPC_ID "${VPC_ID}"

# ── Subnets ───────────────────────────────────────────────────────────────────
log "Creating public subnet (${PUBLIC_SUBNET_CIDR})..."
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" \
  --cidr-block "${PUBLIC_SUBNET_CIDR}" \
  --availability-zone "${AVAILABILITY_ZONE}" \
  --region "${AWS_REGION}" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources "${PUBLIC_SUBNET_ID}" --tags \
  Key=Name,Value=codeguard-public-subnet \
  Key=Project,Value="${PROJECT_TAG}"
aws ec2 modify-subnet-attribute --subnet-id "${PUBLIC_SUBNET_ID}" \
  --map-public-ip-on-launch
log "Public subnet: ${PUBLIC_SUBNET_ID}"
save PUBLIC_SUBNET_ID "${PUBLIC_SUBNET_ID}"

log "Creating private subnet (${PRIVATE_SUBNET_CIDR})..."
PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" \
  --cidr-block "${PRIVATE_SUBNET_CIDR}" \
  --availability-zone "${AVAILABILITY_ZONE}" \
  --region "${AWS_REGION}" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources "${PRIVATE_SUBNET_ID}" --tags \
  Key=Name,Value=codeguard-private-subnet \
  Key=Project,Value="${PROJECT_TAG}"
log "Private subnet: ${PRIVATE_SUBNET_ID}"
save PRIVATE_SUBNET_ID "${PRIVATE_SUBNET_ID}"

# ── Internet Gateway ──────────────────────────────────────────────────────────
log "Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "${AWS_REGION}" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
aws ec2 create-tags --resources "${IGW_ID}" --tags \
  Key=Name,Value=codeguard-igw \
  Key=Project,Value="${PROJECT_TAG}"
log "IGW created and attached: ${IGW_ID}"
save IGW_ID "${IGW_ID}"

# ── Elastic IP for NAT Gateway ────────────────────────────────────────────────
log "Allocating Elastic IP for NAT Gateway..."
NAT_EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --region "${AWS_REGION}" \
  --query 'AllocationId' --output text)
aws ec2 create-tags --resources "${NAT_EIP_ALLOC_ID}" --tags \
  Key=Name,Value=codeguard-nat-eip \
  Key=Project,Value="${PROJECT_TAG}" 2>/dev/null || true
log "NAT EIP allocation: ${NAT_EIP_ALLOC_ID}"
save NAT_EIP_ALLOC_ID "${NAT_EIP_ALLOC_ID}"

# ── NAT Gateway ───────────────────────────────────────────────────────────────
log "Creating NAT Gateway in public subnet..."
NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "${PUBLIC_SUBNET_ID}" \
  --allocation-id "${NAT_EIP_ALLOC_ID}" \
  --region "${AWS_REGION}" \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources "${NAT_GW_ID}" --tags \
  Key=Name,Value=codeguard-nat-gw \
  Key=Project,Value="${PROJECT_TAG}"
log "Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_ID}" --region "${AWS_REGION}"
log "NAT Gateway ready: ${NAT_GW_ID}"
save NAT_GW_ID "${NAT_GW_ID}"

# ── Route Tables ──────────────────────────────────────────────────────────────
log "Creating public route table..."
PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route \
  --route-table-id "${PUBLIC_RT_ID}" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "${IGW_ID}"
aws ec2 associate-route-table \
  --route-table-id "${PUBLIC_RT_ID}" \
  --subnet-id "${PUBLIC_SUBNET_ID}"
aws ec2 create-tags --resources "${PUBLIC_RT_ID}" --tags \
  Key=Name,Value=codeguard-public-rt \
  Key=Project,Value="${PROJECT_TAG}"
log "Public route table: ${PUBLIC_RT_ID}"
save PUBLIC_RT_ID "${PUBLIC_RT_ID}"

log "Creating private route table..."
PRIVATE_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route \
  --route-table-id "${PRIVATE_RT_ID}" \
  --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "${NAT_GW_ID}"
aws ec2 associate-route-table \
  --route-table-id "${PRIVATE_RT_ID}" \
  --subnet-id "${PRIVATE_SUBNET_ID}"
aws ec2 create-tags --resources "${PRIVATE_RT_ID}" --tags \
  Key=Name,Value=codeguard-private-rt \
  Key=Project,Value="${PROJECT_TAG}"
log "Private route table: ${PRIVATE_RT_ID}"
save PRIVATE_RT_ID "${PRIVATE_RT_ID}"

# ── VPC Endpoint: S3 (Gateway type — free, no ENI needed) ────────────────────
log "Creating S3 VPC gateway endpoint..."
S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name "com.amazonaws.${AWS_REGION}.s3" \
  --vpc-endpoint-type Gateway \
  --route-table-ids "${PRIVATE_RT_ID}" \
  --region "${AWS_REGION}" \
  --query 'VpcEndpoint.VpcEndpointId' --output text)
aws ec2 create-tags --resources "${S3_ENDPOINT_ID}" --tags \
  Key=Name,Value=codeguard-s3-endpoint \
  Key=Project,Value="${PROJECT_TAG}"
log "S3 endpoint: ${S3_ENDPOINT_ID}"
save S3_ENDPOINT_ID "${S3_ENDPOINT_ID}"

# ── VPC Endpoint: SNS (Interface type — needs security group, created in 02-security.sh)
# We create a placeholder security group here; 02-security.sh will refine it.
log "Creating placeholder security group for SNS endpoint..."
SNS_ENDPOINT_SG_ID=$(aws ec2 create-security-group \
  --group-name codeguard-sns-endpoint-sg \
  --description "Security group for SNS VPC interface endpoint" \
  --vpc-id "${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "${SNS_ENDPOINT_SG_ID}" \
  --protocol tcp --port 443 \
  --cidr "${PRIVATE_SUBNET_CIDR}"
aws ec2 create-tags --resources "${SNS_ENDPOINT_SG_ID}" --tags \
  Key=Name,Value=codeguard-sns-endpoint-sg \
  Key=Project,Value="${PROJECT_TAG}"
save SNS_ENDPOINT_SG_ID "${SNS_ENDPOINT_SG_ID}"

log "Creating SNS VPC interface endpoint..."
SNS_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --service-name "com.amazonaws.${AWS_REGION}.sns" \
  --vpc-endpoint-type Interface \
  --subnet-ids "${PRIVATE_SUBNET_ID}" \
  --security-group-ids "${SNS_ENDPOINT_SG_ID}" \
  --private-dns-enabled \
  --region "${AWS_REGION}" \
  --query 'VpcEndpoint.VpcEndpointId' --output text)
aws ec2 create-tags --resources "${SNS_ENDPOINT_ID}" --tags \
  Key=Name,Value=codeguard-sns-endpoint \
  Key=Project,Value="${PROJECT_TAG}"
log "SNS endpoint: ${SNS_ENDPOINT_ID}"
save SNS_ENDPOINT_ID "${SNS_ENDPOINT_ID}"

log "01-vpc.sh complete. Resource IDs saved to ${STATE_FILE}"
