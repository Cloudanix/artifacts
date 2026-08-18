#!/usr/bin/env bash
# =============================================================================
# Step: Setup Bastion in Existing VPC
# =============================================================================
# Deploys a bastion EC2 instance into an existing VPC with SSM access.
# Creates security group, IAM role, instance profile, and the EC2 instance.
#
# Required env vars:
#   AWS_REGION
#
# Optional env vars (from state):
#   VPC_ID, PRIV_SUB_1
#
# Outputs:
#   OUTPUT:BASTION_INSTANCE_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION

# =============================================================================
# CONFIGURATION
# =============================================================================

SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-hub-bastion-role"
INSTANCE_PROFILE_NAME="cdx-jit-k8s-hub-bastion-profile"
INSTANCE_NAME="cdx-jit-k8s-hub-bastion"
INSTANCE_TYPE="t3.micro"
TAGS="Key=owner,Value=cloudanix},{Key=purpose,Value=cdx-jit-k8s},{Key=service,Value=bastion},{Key=scope,Value=hub"

# VPC_ID and PRIV_SUB_1 should come from orchestrator state
require_env VPC_ID PRIV_SUB_1

VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
    error "VPC $VPC_ID not found in region $AWS_REGION"
    exit 1
fi

info "VPC: $VPC_ID ($VPC_CIDR)"
info "Subnet: $PRIV_SUB_1"

# =============================================================================
# SECURITY GROUP (idempotent)
# =============================================================================

step "Security Group"
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description "Bastion hub SG - SSM managed, no inbound SSH required" \
        --vpc-id "$VPC_ID" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{$TAGS}]" \
        --query "GroupId" --output text)
    aws ec2 authorize-security-group-egress --group-id "$SG_ID" \
        --protocol "-1" --cidr "0.0.0.0/0" --region "$AWS_REGION" 2>/dev/null || true
    ok "SG created: $SG_ID"
else
    ok "SG exists: $SG_ID"
fi

# =============================================================================
# IAM ROLE + INSTANCE PROFILE (idempotent)
# =============================================================================

step "IAM Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" > /dev/null
    ok "IAM Role created: $ROLE_NAME"
else
    ok "IAM Role exists: $ROLE_NAME"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

step "Instance Profile"
EXISTING_PROFILE=$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query 'InstanceProfile.Arn' --output text 2>/dev/null) || EXISTING_PROFILE=""
if [[ -z "$EXISTING_PROFILE" ]]; then
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" > /dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME" 2>/dev/null || true
    info "Waiting for instance profile propagation..."
    sleep 10
    ok "Instance profile created"
else
    aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME" 2>/dev/null || true
    ok "Instance profile exists"
fi

# =============================================================================
# EC2 INSTANCE (idempotent)
# =============================================================================

step "Bastion Instance"
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=vpc-id,Values=$VPC_ID" \
              "Name=instance-state-name,Values=running,pending,stopped" \
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
    # Start if stopped
    STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
        --query "Reservations[0].Instances[0].State.Name" --output text)
    if [[ "$STATE" == "stopped" ]]; then
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
        ok "Instance restarted"
    fi
fi

# =============================================================================
# WAIT FOR SSM
# =============================================================================

step "SSM Agent"
for i in $(seq 1 20); do
    SSM_STATUS=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" --region "$AWS_REGION" \
        --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
    if [[ "$SSM_STATUS" == "Online" ]]; then
        ok "SSM agent online"; break
    fi
    sleep 5
done

if [[ "$SSM_STATUS" != "Online" ]]; then
    warn "SSM agent not yet online — ensure subnet has NAT or VPC endpoints for SSM"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Bastion setup complete (existing VPC)"
echo "OUTPUT:BASTION_INSTANCE_ID=${INSTANCE_ID}"
