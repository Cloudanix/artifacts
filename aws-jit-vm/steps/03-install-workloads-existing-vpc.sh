#!/usr/bin/env bash
# =============================================================================
# Step: Install VM Workloads (Existing VPC)
# =============================================================================
# Deploys JIT VM workloads into an existing VPC. Creates security groups,
# VPC endpoints, S3 bucket, IAM role, EFS, Cloud Map namespace, ECS cluster,
# task definitions, and services — all within the provided VPC.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, S3_BUCKET_NAME,
#   CDX_API_AUTH_TOKEN, CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN,
#   CDX_DATA_CENTER, CDX_API_BASE
#
# Outputs:
#   OUTPUT:CLUSTER_NAME, OUTPUT:ECS_SG_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME S3_BUCKET_NAME \
    CDX_API_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN \
    CDX_DATA_CENTER CDX_API_BASE

# =============================================================================
# DISCOVER EXISTING VPC
# =============================================================================

step "Discover Existing VPC"

# The orchestrator provides VPC_ID and subnet IDs via env (set in state)
require_env VPC_ID PRIV_SUB_1 PRIV_SUB_2

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

CLUSTER_NAME="${PROJECT_NAME}-cluster"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
NAMESPACE="${PROJECT_NAME}-local"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

info "VPC: $VPC_ID ($VPC_CIDR)"
info "Private Subnets: $PRIV_SUB_1, $PRIV_SUB_2"

# =============================================================================
# SECURITY GROUPS
# =============================================================================

step "Security Groups"
ECS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$ECS_SG" || "$ECS_SG" == "None" ]]; then
    ECS_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ecs-sg" \
        --description "ECS tasks - sshpiper(2222), proxyserver(8079), NFS(2049)" \
        --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2222 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8079 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG" --region "$AWS_REGION" > /dev/null
    ok "ECS SG created: $ECS_SG"
else
    ok "ECS SG exists: $ECS_SG"
fi

VPCE_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-vpce-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$VPCE_SG" || "$VPCE_SG" == "None" ]]; then
    VPCE_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-vpce-sg" \
        --description "VPC Endpoints - HTTPS from VPC" --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$VPCE_SG" --protocol tcp --port 443 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
fi

# =============================================================================
# VPC ENDPOINTS (SSM)
# =============================================================================

step "VPC Endpoints"
for SVC in ssm ssmmessages ec2messages; do
    EXISTING=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.${SVC}" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "$AWS_REGION" 2>/dev/null)
    if [[ -z "$EXISTING" || "$EXISTING" == "None" ]]; then
        aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
            --service-name "com.amazonaws.${AWS_REGION}.${SVC}" \
            --subnet-ids "$PRIV_SUB_1" "$PRIV_SUB_2" --security-group-ids "$VPCE_SG" \
            --private-dns-enabled --region "$AWS_REGION" > /dev/null
    fi
done
ok "VPC endpoints ready"

# =============================================================================
# S3 BUCKET
# =============================================================================

step "S3 Bucket"
if ! aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
fi
aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --versioning-configuration Status=Enabled 2>/dev/null || true
ok "S3: $S3_BUCKET_NAME"

# =============================================================================
# IAM ROLE
# =============================================================================

step "IAM Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "IAM Role created: $ROLE_NAME"
else
    ok "IAM Role exists: $ROLE_NAME"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true

# =============================================================================
# EFS
# =============================================================================

step "EFS"
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
    EFS_ID=$(aws efs create-file-system --performance-mode generalPurpose --encrypted \
        --tags "Key=Name,Value=${PROJECT_NAME}-efs" "Key=created_by,Value=cloudanix" \
        --query 'FileSystemId' --output text --region "$AWS_REGION")
    for i in $(seq 1 20); do
        STATE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
            --query 'FileSystems[0].LifeCycleState' --output text --region "$AWS_REGION")
        [[ "$STATE" == "available" ]] && break; sleep 5
    done
    ok "EFS created: $EFS_ID"
else
    ok "EFS exists: $EFS_ID"
fi

# Mount targets
for SUB in "$PRIV_SUB_1" "$PRIV_SUB_2"; do
    EXISTING_MT=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query "MountTargets[?SubnetId=='${SUB}'].MountTargetId | [0]" --output text --region "$AWS_REGION" 2>/dev/null)
    if [[ -z "$EXISTING_MT" || "$EXISTING_MT" == "None" ]]; then
        aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUB" \
            --security-groups "$ECS_SG" --region "$AWS_REGION" > /dev/null
    fi
done

# =============================================================================
# ECS CLUSTER
# =============================================================================

step "ECS Cluster"
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
    --query 'clusters[0].status' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --capacity-providers FARGATE \
        --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
        --configuration "executeCommandConfiguration={logging=DEFAULT}" \
        --tags "key=Purpose,value=vm-jit" "key=created_by,value=cloudanix" \
        --region "$AWS_REGION" > /dev/null
    ok "Cluster created: $CLUSTER_NAME"
else
    ok "Cluster exists: $CLUSTER_NAME"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "VM workload infrastructure deployed (existing VPC)"
echo "OUTPUT:CLUSTER_NAME=${CLUSTER_NAME}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
