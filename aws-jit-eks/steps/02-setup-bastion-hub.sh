#!/usr/bin/env bash
# =============================================================================
# Step: Setup Bastion Hub (New VPC)
# =============================================================================
# Creates the EKS bastion hub infrastructure in a new VPC: VPC, subnets, IGW,
# NAT gateway, route tables, security group, IAM role, instance profile, and
# EC2 bastion instance with SSM access.
#
# Required env vars:
#   AWS_REGION, VPC_CIDR
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:BASTION_INSTANCE_ID, OUTPUT:SG_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION VPC_CIDR

# =============================================================================
# CONFIGURATION
# =============================================================================

VPC_NAME="cdx-jit-k8s-hub-vpc"
SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-hub-bastion-role"
INSTANCE_PROFILE_NAME="cdx-jit-k8s-hub-bastion-profile"
INSTANCE_NAME="cdx-jit-k8s-hub-bastion"
INSTANCE_TYPE="t3.micro"
TAGS="Key=owner,Value=cloudanix},{Key=purpose,Value=cdx-jit-k8s},{Key=service,Value=bastion},{Key=scope,Value=hub"

VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PUB_SUB_1_CIDR="${VPC_BASE}.1.0/24"
PUB_SUB_2_CIDR="${VPC_BASE}.2.0/24"
PRIV_SUB_1_CIDR="${VPC_BASE}.3.0/24"
PRIV_SUB_2_CIDR="${VPC_BASE}.4.0/24"

AZ_1=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
    --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
    --query "AvailabilityZones[1].ZoneName" --output text)

info "Region: $AWS_REGION | VPC CIDR: $VPC_CIDR"
info "AZs: $AZ_1, $AZ_2"

# =============================================================================
# VPC (idempotent)
# =============================================================================

step "VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" "Name=cidr,Values=$VPC_CIDR" \
    --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{$TAGS}]" \
        --query "Vpc.VpcId" --output text)
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$AWS_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$AWS_REGION"

# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=cdx-jit-k8s-hub-igw" \
    --query "InternetGateways[0].InternetGatewayId" --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway --region "$AWS_REGION" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-igw},{$TAGS}]" \
        --query "InternetGateway.InternetGatewayId" --output text)
fi
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION" 2>/dev/null || true

# =============================================================================
# SUBNETS
# =============================================================================

step "Subnets"
find_or_create_subnet() {
    local vpc_id=$1 cidr=$2 az=$3 name=$4
    local sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=$name" \
        --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null)
    if [[ -z "$sub_id" || "$sub_id" == "None" ]]; then
        sub_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" \
            --region "$AWS_REGION" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name},{$TAGS}]" \
            --query 'Subnet.SubnetId' --output text)
    fi
    echo "$sub_id"
}

PUB_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PUB_SUB_1_CIDR" "$AZ_1" "cdx-jit-k8s-hub-public-1")
PUB_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PUB_SUB_2_CIDR" "$AZ_2" "cdx-jit-k8s-hub-public-2")
PRIV_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PRIV_SUB_1_CIDR" "$AZ_1" "cdx-jit-k8s-hub-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PRIV_SUB_2_CIDR" "$AZ_2" "cdx-jit-k8s-hub-private-2")
ok "Subnets: $PUB_SUB_1, $PUB_SUB_2, $PRIV_SUB_1, $PRIV_SUB_2"

# =============================================================================
# NAT GATEWAY + ROUTE TABLES
# =============================================================================

step "NAT Gateway"
NAT_GW_ID=$(aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=cdx-jit-k8s-hub-natgw" "Name=state,Values=available,pending" \
    --query "NatGateways[0].NatGatewayId" --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$NAT_GW_ID" || "$NAT_GW_ID" == "None" ]]; then
    EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION" \
        --query "AllocationId" --output text)
    NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP_ALLOC" \
        --region "$AWS_REGION" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-natgw},{$TAGS}]" \
        --query "NatGateway.NatGatewayId" --output text)
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" --region "$AWS_REGION"
    ok "NAT created: $NAT_GW_ID"
else
    ok "NAT exists: $NAT_GW_ID"
fi

# Public RT
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=cdx-jit-k8s-hub-public-rt" \
    --query "RouteTables[0].RouteTableId" --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-public-rt},{$TAGS}]" \
        --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_1" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_2" --region "$AWS_REGION" > /dev/null
fi

# Private RT
PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=cdx-jit-k8s-hub-private-rt" \
    --query "RouteTables[0].RouteTableId" --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$PRIV_RT" || "$PRIV_RT" == "None" ]]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-private-rt},{$TAGS}]" \
        --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_1" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_2" --region "$AWS_REGION" > /dev/null
fi
ok "Route tables configured"

# =============================================================================
# SECURITY GROUP + IAM + INSTANCE
# =============================================================================

step "Security Group"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description "Bastion hub SG - SSM managed, no inbound SSH required" \
        --vpc-id "$VPC_ID" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{$TAGS}]" \
        --query "GroupId" --output text)
fi
aws ec2 authorize-security-group-egress --group-id "$SG_ID" --protocol "-1" --cidr "0.0.0.0/0" --region "$AWS_REGION" 2>/dev/null || true
ok "SG: $SG_ID"

step "IAM Role + Instance Profile"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" > /dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

EXISTING_PROFILE=$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query 'InstanceProfile.Arn' --output text 2>/dev/null) || EXISTING_PROFILE=""
if [[ -z "$EXISTING_PROFILE" ]]; then
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" > /dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
    sleep 10
else
    aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
fi
ok "IAM ready: $ROLE_NAME"

step "Bastion Instance"
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,pending,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    AMI_ID=$(aws ec2 describe-images --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text --region "$AWS_REGION")

    INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$PRIV_SUB_1" --security-group-ids "$SG_ID" \
        --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{$TAGS}]" \
        --region "$AWS_REGION" --query "Instances[0].InstanceId" --output text)
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    ok "Instance launched: $INSTANCE_ID"
else
    ok "Instance exists: $INSTANCE_ID"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Bastion hub setup complete"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:BASTION_INSTANCE_ID=${INSTANCE_ID}"
echo "OUTPUT:SG_ID=${SG_ID}"
