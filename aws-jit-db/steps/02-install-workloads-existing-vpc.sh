#!/usr/bin/env bash
# =============================================================================
# Step: Install Workloads (Existing VPC)
# =============================================================================
# Installs JIT DB proxy workloads into an existing VPC. Prompts for VPC ID and
# subnet IDs. Creates security groups, ECS cluster, IAM roles, EFS, secrets,
# S3 bucket, task definitions, and ECS services.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, BUCKET_NAME, SECRET_NAME, CDX_AUTH_TOKEN,
#   CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN, CDX_DC, CDX_API_BASE,
#   ECS_CLUSTER_NAME, ENABLE_DAM
#
# Outputs:
#   OUTPUT:ECS_CLUSTER_ARN, OUTPUT:ECS_SG_ID, OUTPUT:EFS_ID, OUTPUT:SECRET_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME BUCKET_NAME SECRET_NAME \
    CDX_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN CDX_DC CDX_API_BASE \
    ECS_CLUSTER_NAME ENABLE_DAM

# =============================================================================
# PROMPT FOR EXISTING VPC DETAILS
# =============================================================================

step "Existing VPC Configuration"
VPC_ID=$(prompt_with_default "VPC ID" "")
if [[ -z "$VPC_ID" ]]; then
    error "VPC ID is required"; exit 1
fi

PRIV_SUB_1=$(prompt_with_default "Private Subnet 1 ID" "")
if [[ -z "$PRIV_SUB_1" ]]; then
    error "Private Subnet 1 ID is required"; exit 1
fi

PRIV_SUB_2=$(prompt_with_default "Private Subnet 2 ID" "")
if [[ -z "$PRIV_SUB_2" ]]; then
    error "Private Subnet 2 ID is required"; exit 1
fi

# Validate VPC exists
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" \
    --query "Vpcs[0].CidrBlock" --output text 2>/dev/null)
if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
    error "VPC $VPC_ID not found in region $AWS_REGION"; exit 1
fi
ok "VPC validated: $VPC_ID ($VPC_CIDR)"

# Validate subnets belong to VPC
for SUB_ID in "$PRIV_SUB_1" "$PRIV_SUB_2"; do
    SUB_VPC=$(aws ec2 describe-subnets --subnet-ids "$SUB_ID" --region "$AWS_REGION" \
        --query "Subnets[0].VpcId" --output text 2>/dev/null)
    if [[ "$SUB_VPC" != "$VPC_ID" ]]; then
        error "Subnet $SUB_ID does not belong to VPC $VPC_ID"; exit 1
    fi
done
ok "Subnets validated: $PRIV_SUB_1, $PRIV_SUB_2"

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

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
    ok "Secret exists: $SECRET_NAME"
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
    sleep 10
    ok "EFS created: $EFS_ID"
else
    ok "EFS exists: $EFS_ID"
fi

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

ok "Install workloads (existing VPC) complete"
echo "OUTPUT:ECS_CLUSTER_ARN=${CLUSTER_ARN}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
echo "OUTPUT:EFS_ID=${EFS_ID}"
echo "OUTPUT:SECRET_ARN=${SECRET_ARN}"
