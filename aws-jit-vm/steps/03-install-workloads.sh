#!/usr/bin/env bash
# =============================================================================
# Step: Install VM Workloads (New VPC)
# =============================================================================
# Creates the full JIT VM infrastructure in a new VPC: VPC, subnets, NAT,
# security groups, VPC endpoints, S3 bucket, IAM role, EFS, Cloud Map
# namespace, ECS cluster, task definitions, and services.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, VPC_CIDR, S3_BUCKET_NAME,
#   CDX_API_AUTH_TOKEN, CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN,
#   CDX_DATA_CENTER, CDX_API_BASE
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:ECS_SG_ID, OUTPUT:CLUSTER_NAME, OUTPUT:EFS_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME VPC_CIDR S3_BUCKET_NAME \
    CDX_API_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN \
    CDX_DATA_CENTER CDX_API_BASE

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PRIV_SUB_1_CIDR="${VPC_BASE}.3.0/24"
PRIV_SUB_2_CIDR="${VPC_BASE}.4.0/24"
PUB_SUB_1_CIDR="${VPC_BASE}.1.0/24"
PUB_SUB_2_CIDR="${VPC_BASE}.2.0/24"
AZ_1="${AWS_REGION}a"
AZ_2="${AWS_REGION}b"
CLUSTER_NAME="${PROJECT_NAME}-cluster"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
NAMESPACE="${PROJECT_NAME}-local"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Project: $PROJECT_NAME"

# =============================================================================
# VPC (idempotent)
# =============================================================================

step "VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" "Name=cidr,Values=${VPC_CIDR}" \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Purpose,Value=vm-jit},{Key=created_by,Value=cloudanix}]" \
        --query 'Vpc.VpcId' --output text --region "$AWS_REGION")
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$AWS_REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$AWS_REGION"
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi

# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
        --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION"
fi

# =============================================================================
# SUBNETS
# =============================================================================

step "Subnets"
find_or_create_subnet() {
    local vpc_id=$1 cidr=$2 az=$3 name=$4
    local sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null)
    if [[ -z "$sub_id" || "$sub_id" == "None" ]]; then
        sub_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}}]" \
            --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
    fi
    echo "$sub_id"
}

PUB_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PUB_SUB_1_CIDR" "$AZ_1" "${PROJECT_NAME}-public-1")
PUB_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PUB_SUB_2_CIDR" "$AZ_2" "${PROJECT_NAME}-public-2")
PRIV_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PRIV_SUB_1_CIDR" "$AZ_1" "${PROJECT_NAME}-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PRIV_SUB_2_CIDR" "$AZ_2" "${PROJECT_NAME}-private-2")
ok "Subnets ready"

# =============================================================================
# NAT GATEWAY + ROUTE TABLES
# =============================================================================

step "NAT Gateway"
NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$NAT_ID" || "$NAT_ID" == "None" ]]; then
    EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region "$AWS_REGION")
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat}]" \
        --query 'NatGateway.NatGatewayId' --output text --region "$AWS_REGION")
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION"
    ok "NAT created: $NAT_ID"
else
    ok "NAT exists: $NAT_ID"
fi

# Route tables (public + private)
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-pub-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-pub-rt}]" \
        --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_1" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_2" --region "$AWS_REGION" > /dev/null
fi

PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-priv-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$PRIV_RT" || "$PRIV_RT" == "None" ]]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-priv-rt}]" \
        --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_1" --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_2" --region "$AWS_REGION" > /dev/null
fi
ok "Route tables configured"

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
fi

VPCE_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-vpce-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$VPCE_SG" || "$VPCE_SG" == "None" ]]; then
    VPCE_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-vpce-sg" \
        --description "VPC Endpoints - HTTPS from VPC" --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$VPCE_SG" --protocol tcp --port 443 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
fi
ok "ECS SG: $ECS_SG | VPCE SG: $VPCE_SG"

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
# S3 BUCKET + IAM ROLE + EFS + CLOUD MAP + ECS (condensed)
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
ok "S3: $S3_BUCKET_NAME"

step "IAM Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true
ok "IAM Role: $ROLE_NAME"

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
fi
ok "EFS: $EFS_ID"

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
fi
ok "Cluster: $CLUSTER_NAME"

# =============================================================================
# OUTPUT
# =============================================================================

ok "VM workload infrastructure deployed"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
echo "OUTPUT:CLUSTER_NAME=${CLUSTER_NAME}"
echo "OUTPUT:EFS_ID=${EFS_ID}"
