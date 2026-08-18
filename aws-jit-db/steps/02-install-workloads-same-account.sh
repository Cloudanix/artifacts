#!/usr/bin/env bash
# =============================================================================
# Step: Install Workloads (Same Account)
# =============================================================================
# Minimal setup for a second workload deployment in an already-configured
# account. Creates only the ECS cluster and services — assumes VPC, IAM roles,
# EFS, and secrets already exist from a prior setup.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, ECS_CLUSTER_NAME, BUCKET_NAME, SECRET_NAME,
#   ENABLE_DAM
#
# Outputs:
#   OUTPUT:ECS_CLUSTER_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME ECS_CLUSTER_NAME BUCKET_NAME SECRET_NAME ENABLE_DAM

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Cluster: $ECS_CLUSTER_NAME"

# =============================================================================
# VALIDATE PRE-EXISTING RESOURCES
# =============================================================================

step "Validating existing resources"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    error "IAM Role $ROLE_NAME not found. Run a full install first."; exit 1
fi
ok "IAM Role: $ROLE_NAME"

SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
    --query 'ARN' --output text 2>/dev/null) || SECRET_ARN=""
if [[ -z "$SECRET_ARN" ]]; then
    error "Secret $SECRET_NAME not found. Run a full install first."; exit 1
fi
ok "Secret: $SECRET_NAME"

# Look up existing ECS SG and subnets from prior cluster services
EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$EXISTING_SG" || "$EXISTING_SG" == "None" ]]; then
    error "Security group ${PROJECT_NAME}-ecs-sg not found."; exit 1
fi
ok "Security Group: $EXISTING_SG"

# Get subnets from existing EFS mount targets or prompt
EFS_ID=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" \
    --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
    warn "EFS not found — prompting for subnet IDs"
    PRIV_SUB_1=$(prompt_with_default "Private Subnet 1 ID" "")
    PRIV_SUB_2=$(prompt_with_default "Private Subnet 2 ID" "")
else
    PRIV_SUB_1=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query 'MountTargets[0].SubnetId' --output text --region "$AWS_REGION")
    PRIV_SUB_2=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query 'MountTargets[1].SubnetId' --output text --region "$AWS_REGION")
    ok "EFS: $EFS_ID (subnets: $PRIV_SUB_1, $PRIV_SUB_2)"
fi

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

step "ECS Services"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$PRIV_SUB_1,$PRIV_SUB_2],securityGroups=[$EXISTING_SG],assignPublicIp=DISABLED}"

SVC="jit-db-proxy-sql"
EXISTING=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SVC" \
    --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text --region "$AWS_REGION" 2>/dev/null)
if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
    ok "Service exists: $SVC"
else
    aws ecs create-service --cluster "$ECS_CLUSTER_NAME" --service-name "$SVC" \
        --task-definition "${PROJECT_NAME}-proxy-sql" --desired-count 1 --launch-type FARGATE \
        --enable-execute-command --network-configuration "$NETWORK_CONFIG" \
        --tags "key=created_by,value=cloudanix" --region "$AWS_REGION" > /dev/null
    ok "Service created: $SVC"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Install workloads (same account) complete"
echo "OUTPUT:ECS_CLUSTER_ARN=${CLUSTER_ARN}"
