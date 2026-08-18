#!/usr/bin/env bash
# =============================================================================
# Step: Install Workloads (New VPC)
# =============================================================================
# Creates a new VPC with subnets, NAT gateway, route tables, security groups,
# ECS cluster, IAM roles, EFS, Secrets Manager secret, S3 bucket, task
# definitions, and ECS services for the JIT DB proxy workloads.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, VPC_CIDR, BUCKET_NAME, SECRET_NAME,
#   CDX_AUTH_TOKEN, CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN, CDX_DC,
#   CDX_API_BASE, ECS_CLUSTER_NAME, ENABLE_DAM
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:ECS_CLUSTER_ARN, OUTPUT:ECS_SG_ID, OUTPUT:EFS_ID,
#   OUTPUT:SECRET_ARN, OUTPUT:PRIVATE_SUBNET_1_ID, OUTPUT:PRIVATE_SUBNET_2_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME VPC_CIDR BUCKET_NAME SECRET_NAME \
    CDX_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN CDX_DC CDX_API_BASE \
    ECS_CLUSTER_NAME ENABLE_DAM

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PRIVATE_SUBNET_1_CIDR="${VPC_BASE}.3.0/24"
PRIVATE_SUBNET_2_CIDR="${VPC_BASE}.4.0/24"
PUBLIC_SUBNET_1_CIDR="${VPC_BASE}.1.0/24"
AZ_1="${AWS_REGION}a"
AZ_2="${AWS_REGION}b"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Project: $PROJECT_NAME"

# =============================================================================
# VPC
# =============================================================================

step "VPC"
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" "Name=cidr,Values=${VPC_CIDR}" \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Purpose,Value=db-jit},{Key=created_by,Value=cloudanix}]" \
        --query 'Vpc.VpcId' --output text --region "$AWS_REGION")
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$AWS_REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$AWS_REGION"
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi

# =============================================================================
# SUBNETS & NAT GATEWAY
# =============================================================================

step "Subnets"
find_or_create_subnet() {
    local cidr=$1 az=$2 name=$3
    local sub_id
    sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null)
    if [[ -z "$sub_id" || "$sub_id" == "None" ]]; then
        sub_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=created_by,Value=cloudanix}]" \
            --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
    fi
    echo "$sub_id"
}

PUB_SUB_1=$(find_or_create_subnet "$PUBLIC_SUBNET_1_CIDR" "$AZ_1" "${PROJECT_NAME}-public-1")
PRIV_SUB_1=$(find_or_create_subnet "$PRIVATE_SUBNET_1_CIDR" "$AZ_1" "${PROJECT_NAME}-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$PRIVATE_SUBNET_2_CIDR" "$AZ_2" "${PROJECT_NAME}-private-2")
ok "Subnets: public=$PUB_SUB_1 private=$PRIV_SUB_1,$PRIV_SUB_2"

step "Internet & NAT Gateway"
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
        --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION"
fi

NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$NAT_ID" || "$NAT_ID" == "None" ]]; then
    EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region "$AWS_REGION")
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat}]" \
        --query 'NatGateway.NatGatewayId' --output text --region "$AWS_REGION")
    info "Waiting for NAT Gateway..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION"
    ok "NAT created: $NAT_ID"
else
    ok "NAT exists: $NAT_ID"
fi

# Route tables (private → NAT)
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
# SECURITY GROUP
# =============================================================================

step "Security Group"
ECS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$ECS_SG" || "$ECS_SG" == "None" ]]; then
    ECS_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ecs-sg" \
        --description "ECS tasks - proxy(5432/3306), NFS(2049)" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-ecs-sg},{Key=created_by,Value=cloudanix}]" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 5432 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 3306 --cidr "$VPC_CIDR" --region "$AWS_REGION" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG" --region "$AWS_REGION" > /dev/null
    ok "ECS SG created: $ECS_SG"
else
    ok "ECS SG exists: $ECS_SG"
fi

# =============================================================================
# S3 BUCKET
# =============================================================================

step "S3 Bucket"
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    ok "S3 exists: $BUCKET_NAME"
else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' > /dev/null
    ok "S3 created: $BUCKET_NAME"
fi

# =============================================================================
# SECRETS MANAGER
# =============================================================================

step "Secrets Manager"
SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
    --query 'ARN' --output text 2>/dev/null) || SECRET_ARN=""
if [[ -z "$SECRET_ARN" ]]; then
    SECRET_JSON=$(jq -n \
        --arg token "$CDX_AUTH_TOKEN" --arg sig "$CDX_SIGNATURE_SECRET_KEY" \
        --arg sentry "$CDX_SENTRY_DSN" --arg dc "$CDX_DC" --arg api "$CDX_API_BASE" \
        '{CDX_API_AUTH_TOKEN:$token,CDX_SIGNATURE_SECRET_KEY:$sig,CDX_SENTRY_DSN:$sentry,CDX_DC:$dc,CDX_API_BASE:$api}')
    SECRET_ARN=$(aws secretsmanager create-secret --name "$SECRET_NAME" \
        --secret-string "$SECRET_JSON" --region "$AWS_REGION" \
        --tags "Key=created_by,Value=cloudanix" \
        --query 'ARN' --output text)
    ok "Secret created: $SECRET_NAME"
else
    ok "Secret exists: $SECRET_NAME ($SECRET_ARN)"
fi

# =============================================================================
# IAM ROLE
# =============================================================================

step "IAM Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=created_by,Value=cloudanix" > /dev/null
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
EFS_ID=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
    EFS_ID=$(aws efs create-file-system --performance-mode generalPurpose --encrypted \
        --tags "Key=Name,Value=${PROJECT_NAME}-efs" "Key=created_by,Value=cloudanix" \
        --query 'FileSystemId' --output text --region "$AWS_REGION")
    info "Waiting for EFS..."
    aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" > /dev/null
    sleep 10
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
CLUSTER_ARN=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" \
    --query 'clusters[?status==`ACTIVE`].clusterArn | [0]' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
    CLUSTER_ARN=$(aws ecs create-cluster --cluster-name "$ECS_CLUSTER_NAME" \
        --capacity-providers FARGATE \
        --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
        --configuration "executeCommandConfiguration={logging=DEFAULT}" \
        --tags "key=Purpose,value=db-jit" "key=created_by,value=cloudanix" \
        --query 'cluster.clusterArn' --output text --region "$AWS_REGION")
    ok "Cluster created: $ECS_CLUSTER_NAME"
else
    ok "Cluster exists: $ECS_CLUSTER_NAME"
fi

# =============================================================================
# TASK DEFINITIONS & SERVICES
# =============================================================================

step "Task Definitions"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || true

cat > /tmp/td-proxy-sql.json << EOF
{
    "family":"${PROJECT_NAME}-proxy-sql","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],
    "cpu":"512","memory":"1024","executionRoleArn":"${ROLE_ARN}","taskRoleArn":"${ROLE_ARN}",
    "containerDefinitions":[{"name":"proxy-sql","image":"${ECR_PREFIX}/cloudanix/ecr-aws-jit-proxy-sql:latest",
    "essential":true,"portMappings":[{"containerPort":5432,"protocol":"tcp"}],
    "secrets":[{"name":"CDX_API_AUTH_TOKEN","valueFrom":"${SECRET_ARN}:CDX_API_AUTH_TOKEN::"},
    {"name":"CDX_SIGNATURE_SECRET_KEY","valueFrom":"${SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"}],
    "logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"proxy-sql"}}}]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxy-sql.json --region "$AWS_REGION" > /dev/null
ok "Task def: ${PROJECT_NAME}-proxy-sql"

cat > /tmp/td-proxy-server.json << EOF
{
    "family":"${PROJECT_NAME}-proxy-server","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],
    "cpu":"512","memory":"1024","executionRoleArn":"${ROLE_ARN}","taskRoleArn":"${ROLE_ARN}",
    "containerDefinitions":[{"name":"proxy-server","image":"${ECR_PREFIX}/cloudanix/ecr-aws-jit-proxy-server:latest",
    "essential":true,"portMappings":[{"containerPort":8079,"protocol":"tcp"}],
    "environment":[{"name":"CDX_DC","value":"${CDX_DC}"},{"name":"CDX_API_BASE","value":"${CDX_API_BASE}"},
    {"name":"AWS_DEFAULT_REGION","value":"${AWS_REGION}"},{"name":"S3_BUCKET","value":"${BUCKET_NAME}"}],
    "secrets":[{"name":"CDX_API_AUTH_TOKEN","valueFrom":"${SECRET_ARN}:CDX_API_AUTH_TOKEN::"},
    {"name":"CDX_SIGNATURE_SECRET_KEY","valueFrom":"${SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
    {"name":"CDX_SENTRY_DSN","valueFrom":"${SECRET_ARN}:CDX_SENTRY_DSN::"}],
    "logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"proxy-server"}}}]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxy-server.json --region "$AWS_REGION" > /dev/null
ok "Task def: ${PROJECT_NAME}-proxy-server"

step "ECS Services"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$PRIV_SUB_1,$PRIV_SUB_2],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}"

for SVC_NAME in "jit-db-proxy-sql:${PROJECT_NAME}-proxy-sql" "jit-db-proxy-server:${PROJECT_NAME}-proxy-server"; do
    SVC="${SVC_NAME%%:*}"
    TD="${SVC_NAME##*:}"
    EXISTING=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SVC" \
        --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text --region "$AWS_REGION" 2>/dev/null)
    if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
        ok "Service exists: $SVC"
    else
        aws ecs create-service --cluster "$ECS_CLUSTER_NAME" --service-name "$SVC" \
            --task-definition "$TD" --desired-count 1 --launch-type FARGATE \
            --enable-execute-command --network-configuration "$NETWORK_CONFIG" \
            --tags "key=created_by,value=cloudanix" --region "$AWS_REGION" > /dev/null
        ok "Service created: $SVC"
    fi
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "Install workloads (new VPC) complete"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:ECS_CLUSTER_ARN=${CLUSTER_ARN}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
echo "OUTPUT:EFS_ID=${EFS_ID}"
echo "OUTPUT:SECRET_ARN=${SECRET_ARN}"
echo "OUTPUT:PRIVATE_SUBNET_1_ID=${PRIV_SUB_1}"
echo "OUTPUT:PRIVATE_SUBNET_2_ID=${PRIV_SUB_2}"
