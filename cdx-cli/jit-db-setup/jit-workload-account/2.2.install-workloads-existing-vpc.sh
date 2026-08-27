#!/bin/bash
set -e  
set -u  


prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    while true; do
        read -p "$prompt (y/n) [$default_value]: " yn
        yn=${yn:-$default_value}
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code"
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Function to wait for VPC endpoint to be available
wait_for_endpoint() {
    local endpoint_id=$1
    local max_attempts=20
    local wait_time=30
    local attempt=1
    
    log "Waiting for endpoint ${endpoint_id} to be available..."
    while [ $attempt -le $max_attempts ]; do
        status=$(aws ec2 describe-vpc-endpoints \
            --vpc-endpoint-ids "$endpoint_id" \
            --query 'VpcEndpoints[0].State' \
            --output text)
        
        if [ "$status" = "available" ]; then
            log "Endpoint is available"
            return 0
        fi
        log "Attempt $attempt of $max_attempts, waiting ${wait_time} seconds..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    log "Endpoint creation verification failed"
    return 1
}

# Function to wait for the secret to exist
wait_for_secret() {
    local secret_name=$1
    local max_attempts=10
    local wait_time=30
    local attempt=1
    
    echo "Waiting for secret ${secret_name} to be available..."
    
    while [ $attempt -le $max_attempts ]; do
        if aws secretsmanager describe-secret --secret-id "${secret_name}" --query "Name" --output text | grep -q "${secret_name}"; then
            echo "Secret ${secret_name} is available."
            return 0
        fi
        echo "Attempt $attempt of $max_attempts, waiting ${wait_time} seconds..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    echo "Secret creation verification failed."
    return 1
}

# Function to wait for NAT Gateway
wait_for_nat_gateway() {
    local nat_id=$1
    local timeout=300
    local interval=30
    local elapsed=0
    
    log "Waiting for NAT Gateway ${nat_id} to be available..."
    while [ $elapsed -lt $timeout ]; do
        status=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" --query 'NatGateways[0].State' --output text)
        if [ "$status" = "available" ]; then
            log "NAT Gateway is now available"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log "Still waiting... ($elapsed seconds elapsed)"
    done
    log "Timeout waiting for NAT Gateway"
    return 1
}

# Function to wait for namespace
wait_for_namespace() {
    local namespace_name=$1
    local max_attempts=10
    local wait_time=30
    local attempt=1
    
    log "Waiting for namespace ${namespace_name} to be available..."
    while [ $attempt -le $max_attempts ]; do
        if aws servicediscovery list-namespaces --query "Namespaces[?Name=='${namespace_name}'].Id" --output text | grep -q "ns-"; then
            log "Namespace is available"
            return 0
        fi
        log "Attempt $attempt of $max_attempts, waiting ${wait_time} seconds..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    log "Namespace creation verification failed"
    return 1
}

# Function to create task definition tags JSON
generate_task_tags() {
    local tags_file=$1
    local default_tags='[{"key":"Purpose","value":"database-iam-jit"},{"key":"created_by","value":"cloudanix"}]'
    
    if [ -f "$tags_file" ]; then
        jq -c 'map({"key": .Key, "value": .Value})' "$tags_file"
    else
        echo "$default_tags"
    fi
}

# Function to generate ECS service tags
generate_ecs_service_tags() {
    local tags_file=$1
    local default_tags="key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
    
    if [ -f "$tags_file" ]; then
        local tag_string=$(jq -r '.[] | "key=\(.Key),value=\(.Value)"' "$tags_file" | tr '\n' ' ')
        echo "$tag_string"
    else
        echo "$default_tags"
    fi
}

# Function to apply tags to a resource with different command structure (like S3)
apply_tags_alt() {
    local resource_name=$1
    local tags_file=$2
    local service=$3
    local default_tags='{"TagSet": [{"Key": "Purpose", "Value": "database-iam-jit"}, {"Key": "created_by", "Value": "cloudanix"}]}'
    
    if [ -f "$tags_file" ]; then
        local tag_set=$(jq -c '{TagSet: .}' "$tags_file")
        aws $service put-bucket-tagging --bucket "$resource_name" --tagging "$tag_set"
    else
        aws $service put-bucket-tagging --bucket "$resource_name" --tagging "$default_tags"
    fi
}

generate_tag_specs() {
    local resource_type=$1
    local tags_file=$2
    local resource_name="${PROJECT_NAME}-${resource_type}"

    local tags_json

    if [ -f "$tags_file" ]; then
        tags_json=$(jq --arg name "$resource_name" \
            'map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]' "$tags_file")
    else
        tags_json=$(cat <<EOF
[
  {"Key": "Name", "Value": "$resource_name"},
  {"Key": "Purpose", "Value": "database-iam-jit"},
  {"Key": "created_by", "Value": "cloudanix"}
]
EOF
)
    fi

    jq -n --arg rt "$resource_type" --argjson tags "$tags_json" \
        '[{ResourceType: $rt, Tags: $tags}]'
}

# Function to apply tags to logs
apply_logs_tags() {
    local log_group_name=$1
    local tags_file=$2
    local default_tags='{"Purpose": "database-iam-jit", "created_by": "cloudanix"}'
    
    if [ -f "$tags_file" ]; then
        local tags_obj=$(jq 'map({(.Key): .Value}) | add' "$tags_file")
        aws logs tag-log-group --log-group-name "$log_group_name" --tags "$tags_obj"
    else
        aws logs tag-log-group --log-group-name "$log_group_name" --tags "$default_tags"
    fi
}

apply_secret_tags() {
    local secret_arn=$1
    local tags_file=$2

    local tags_json

    if [ -f "$tags_file" ]; then
        tags_json=$(jq -c '.' "$tags_file")
    else
        tags_json='[
            {"Key": "Purpose", "Value": "database-iam-jit"},
            {"Key": "created_by", "Value": "cloudanix"}
        ]'
    fi

    aws secretsmanager tag-resource \
        --secret-id "$secret_arn" \
        --tags "$tags_json"
}

apply_ecr_tags() {
    local repo_arn=$1
    local repo_name=$2
    local tags_file=$3

    local tags_json

    if [ -f "$tags_file" ]; then
        tags_json=$(jq --arg name "$repo_name" '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]
        ' "$tags_file" | jq -c '.')
    else
        tags_json=$(jq -n --arg name "$repo_name" '[
            {Key: "Name", Value: $name},
            {Key: "Purpose", Value: "database-iam-jit"},
            {Key: "created_by", Value: "cloudanix"}
        ]')
    fi

    aws ecr tag-resource \
        --resource-arn "$repo_arn" \
        --tags "$tags_json"
}

apply_ecs_tags() {
    local resource_arn=$1
    local cluster_name=$2
    local tags_file=$3

    local tag_params

    if [ -f "$tags_file" ]; then
        tag_params=$(jq --arg name "$cluster_name" -r '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}] |
            .[] | "key=\(.Key),value=\(.Value)"
        ' "$tags_file" | tr '\n' ' ')
    else
        tag_params="key=Name,value=$cluster_name key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
    fi

    aws ecs tag-resource \
        --resource-arn "$resource_arn" \
        --tags $tag_params
}

generate_efs_tags() {
    local resource_type=$1
    local tags_file=$2
    local resource_name="${PROJECT_NAME}-${resource_type}"

    local tags_json

    if [ -f "$tags_file" ]; then
        tags_json=$(jq --arg name "$resource_name" '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]
        ' "$tags_file")
    else
        tags_json=$(jq -n --arg name "$resource_name" '[
            {"Key": "Name", "Value": $name},
            {"Key": "Purpose", "Value": "database-iam-jit"},
            {"Key": "created_by", "Value": "cloudanix"}
        ]')
    fi

    echo "$tags_json"
}

# Helper: create IAM policy only if it doesn't exist
create_policy_if_not_exists() {
    local policy_name=$1
    local policy_document=$2
    local existing_arn
    existing_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$policy_name'].Arn" --output text 2>/dev/null)
    if [ -n "$existing_arn" ] && [ "$existing_arn" != "None" ] && [ "$existing_arn" != "" ]; then
        log "Policy $policy_name already exists — skipping"
    else
        log "Creating policy $policy_name..."
        aws iam create-policy --policy-name "$policy_name" --policy-document "$policy_document"
    fi
}

# Helper: create ECS service only if it doesn't exist
create_service_if_not_exists() {
    local service_name=$1
    shift
    local existing
    existing=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services "$service_name" \
        --query "services[?status=='ACTIVE'].serviceName | [0]" --output text 2>/dev/null) || existing=""
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        log "ECS Service $service_name already exists — skipping"
    else
        log "Creating ECS Service $service_name..."
        aws ecs create-service "$@"
    fi
}

echo "=== JIT Account Infrastructure Setup (Idempotent) ==="
echo "This script is safe to re-run. Existing resources will be skipped."
echo ""
echo "Please provide the following configuration details:"
# AWS Configuration
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $ACCOUNT_ID"
# Project Configuration
PROJECT_NAME="cdx-jit-db"

# Ask about DAM setup
echo ""
ENABLE_DAM=false
if prompt_yes_no "Enable Database Activity Monitoring (DAM)?" "n"; then
    ENABLE_DAM=true
    echo "DAM will be enabled"
else
    echo "DAM will be disabled (only ProxySQL services)"
fi

# Network Configuration
VPC_ID=$(prompt_with_default "VPC ID" "vpc-xxxxxxxx")
PRIVATE_SUBNET_1_ID=$(prompt_with_default "Private Subnet 1 ID" "subnet-xxxxxxxx")
PRIVATE_SUBNET_2_ID=$(prompt_with_default "Private Subnet 2 ID" "subnet-xxxxxxxx")
PUBLIC_SUBNET_1_ID=$(prompt_with_default "Public Subnet 1 ID" "subnet-xxxxxxxx")
PUBLIC_SUBNET_2_ID=$(prompt_with_default "Public Subnet 2 ID" "subnet-xxxxxxxx")
BUCKET_NAME=$(prompt_with_default "Enter S3 bucketname according to cdx-jit-db-logs-<org_name> pattern" "cdx-jit-db-logs")
# ECS Configuration
ECS_CLUSTER_NAME="cdx-jit-db-cluster"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"
LOG_GROUP_NAME_3="/ecs/${PROJECT_NAME}/query-logging"

# DAM-specific log groups
if [ "$ENABLE_DAM" = true ]; then
    LOG_GROUP_NAME_4="/ecs/${PROJECT_NAME}/dam-server"
    LOG_GROUP_NAME_5="/ecs/${PROJECT_NAME}/postgresql"
fi

# Secrets Configuration
SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name" "CDX_SECRETS")
CDX_AUTH_TOKEN=$(prompt_with_default "CDX Auth Token" "AUTH_TOKEN_1234567890")
CDX_SIGNATURE_SECRET_KEY=$(prompt_with_default "CDX Signature Secret Key" "SECRET_1234567890")
CDX_SENTRY_DSN=$(prompt_with_default "CDX Sentry DSN" "CDX_SENTRY_DSN")
CDX_DC=$(prompt_with_default "CDX_DC" "US")
CDX_API_BASE=$(prompt_with_default "CDX_API_BASE" "https://console.cloudanix.com")

# DAM-specific secrets
if [ "$ENABLE_DAM" = true ]; then
    ENCRYPTION_KEY=$(prompt_with_default "ENCRYPTION_KEY" "123890234")
    POSTGRES_PASSWORD=$(prompt_with_default "PostgreSQL Password (leave empty to auto-generate)" "")
    if [ -z "$POSTGRES_PASSWORD" ]; then
        POSTGRES_PASSWORD=$(openssl rand -base64 32)
        echo "Generated PostgreSQL password: $POSTGRES_PASSWORD"
    fi
fi

# Tags configuration
TAGS_FILE=$(prompt_with_default "Path to JSON tags file" "2.4.tag.json")
if [ -n "$TAGS_FILE" ] && [ ! -f "$TAGS_FILE" ]; then
    log "Warning: Tags file $TAGS_FILE not found. Using default tags."
    TAGS_FILE=""
fi

echo -e "\n=== Configuration Summary ==="
echo "AWS Region: $AWS_REGION"
echo "Project Name: $PROJECT_NAME"
echo "ECS Cluster Name: $ECS_CLUSTER_NAME"
echo "Secrets Name: $SECRET_NAME"
echo "DAM Enabled: $ENABLE_DAM"

if [ -n "$TAGS_FILE" ]; then
    echo "Using custom tags from: $TAGS_FILE"
else
    echo "Using default tags"
fi

# ============================================================================
# ECS SERVICE LINKED ROLE (idempotent — || true)
# ============================================================================
log "Ensuring ECS Service Linked Role exists..."
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

# ============================================================================
# IAM ROLE (idempotent — check before create)
# ============================================================================
log "Setting up ECS Task Role and policies..."
ECS_TASK_ROLE_NAME="cdx-ECSTaskRole"

if aws iam get-role --role-name $ECS_TASK_ROLE_NAME >/dev/null 2>&1; then
    log "IAM Role $ECS_TASK_ROLE_NAME already exists — skipping"
else
    log "Creating IAM Role $ECS_TASK_ROLE_NAME..."
    aws iam create-role \
        --role-name $ECS_TASK_ROLE_NAME \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "ecs-tasks.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }'
fi

# ============================================================================
# IAM POLICIES (idempotent — check before create)
# ============================================================================
create_policy_if_not_exists "cdx-ECSSecretsAccessPolicy" '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:'"$AWS_REGION"':'"$ACCOUNT_ID"':secret:*"
        }
    ]
}'

create_policy_if_not_exists "cdx-ECSRDSAssumeRolePolicy" '{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "sts:AssumeRole",
        "Resource": [
            "arn:aws:iam::108953788033:role/cdx-us-east-1-774118602354-role_cross_accntb8a9ad6f",
            "arn:aws:iam::108953788033:role/cdx-us-east-1-774118602354-role_cross_accntaa1187e4"
        ]
    }]
}'

create_policy_if_not_exists "cdx-EFSAccessPolicy" '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:DescribeMountTargets"
            ],
            "Resource": "arn:aws:elasticfilesystem:'"$AWS_REGION"':'"$ACCOUNT_ID"':file-system/*"
        }
    ]
}'

S3_POLICY_NAME="cdx-S3AccessPolicy"
create_policy_if_not_exists "$S3_POLICY_NAME" '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:*",
                "s3-object-lambda:*"
            ],
            "Resource": [
                "arn:aws:s3:::'"$BUCKET_NAME"'",
                "arn:aws:s3:::'"$BUCKET_NAME"'/*"
            ]
        }
    ]
}'

LOGS_POLICY_NAME="cdx-CloudWatchLogsPolicy"
LOG_GROUP_ARNS=(
    "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_1:*"
    "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_2:*"
    "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_3:*"
)
if [ "$ENABLE_DAM" = true ]; then
    LOG_GROUP_ARNS+=(
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_4:*"
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_5:*"
    )
fi
LOG_GROUP_ARNS_JSON=$(printf '"%s",' "${LOG_GROUP_ARNS[@]}")
LOG_GROUP_ARNS_JSON="[${LOG_GROUP_ARNS_JSON%,}]"

create_policy_if_not_exists "$LOGS_POLICY_NAME" "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"logs:*\",
          \"cloudwatch:GenerateQuery\"
        ],
        \"Resource\": $LOG_GROUP_ARNS_JSON
      }
    ]
}"

# ============================================================================
# ATTACH POLICIES (idempotent — attach-role-policy is naturally idempotent)
# ============================================================================
SECRETS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-ECSSecretsAccessPolicy`].Arn' --output text)
RDS_ASSUME_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-ECSRDSAssumeRolePolicy`].Arn' --output text)
EFS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-EFSAccessPolicy`].Arn' --output text)
S3_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$S3_POLICY_NAME'].Arn" --output text)
LOGS_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$LOGS_POLICY_NAME'].Arn" --output text)

aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn $SECRETS_POLICY_ARN
aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn $RDS_ASSUME_POLICY_ARN
aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn $EFS_POLICY_ARN
aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn $S3_POLICY_ARN
aws iam attach-role-policy --role-name $ECS_TASK_ROLE_NAME --policy-arn $LOGS_POLICY_ARN

log "ECS Task Role and policies ready"

# ============================================================================
# CLOUDWATCH LOG GROUPS (idempotent — || true on create)
# ============================================================================
log "Setting up CloudWatch Log Groups..."
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_1 2>/dev/null || log "Log group $LOG_GROUP_NAME_1 already exists"
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_2 2>/dev/null || log "Log group $LOG_GROUP_NAME_2 already exists"
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_3 2>/dev/null || log "Log group $LOG_GROUP_NAME_3 already exists"

apply_logs_tags "$LOG_GROUP_NAME_1" "$TAGS_FILE"
apply_logs_tags "$LOG_GROUP_NAME_2" "$TAGS_FILE"
apply_logs_tags "$LOG_GROUP_NAME_3" "$TAGS_FILE"

if [ "$ENABLE_DAM" = true ]; then
    log "Creating DAM log groups..."
    aws logs create-log-group --log-group-name $LOG_GROUP_NAME_4 2>/dev/null || log "Log group $LOG_GROUP_NAME_4 already exists"
    aws logs create-log-group --log-group-name $LOG_GROUP_NAME_5 2>/dev/null || log "Log group $LOG_GROUP_NAME_5 already exists"
    apply_logs_tags "$LOG_GROUP_NAME_4" "$TAGS_FILE"
    apply_logs_tags "$LOG_GROUP_NAME_5" "$TAGS_FILE"
fi

# ============================================================================
# SECRETS MANAGER (idempotent — check before create)
# ============================================================================
log "Setting up Secrets Manager..."

if [ "$ENABLE_DAM" = true ]; then
    SECRET_STRING="{\"CDX_AUTH_TOKEN\": \"$CDX_AUTH_TOKEN\", \"CDX_SIGNATURE_SECRET_KEY\": \"$CDX_SIGNATURE_SECRET_KEY\", \"CDX_SENTRY_DSN\": \"$CDX_SENTRY_DSN\", \"CDX_DC\": \"$CDX_DC\", \"CDX_API_BASE\": \"$CDX_API_BASE\", \"CDX_LOGGING_S3_BUCKET\": \"$BUCKET_NAME\", \"POSTGRES_PASSWORD\": \"$POSTGRES_PASSWORD\", \"ENCRYPTION_KEY\": \"$ENCRYPTION_KEY\" }"
else
    SECRET_STRING="{\"CDX_AUTH_TOKEN\": \"$CDX_AUTH_TOKEN\", \"CDX_SIGNATURE_SECRET_KEY\": \"$CDX_SIGNATURE_SECRET_KEY\", \"CDX_SENTRY_DSN\": \"$CDX_SENTRY_DSN\", \"CDX_DC\": \"$CDX_DC\", \"CDX_API_BASE\": \"$CDX_API_BASE\", \"CDX_LOGGING_S3_BUCKET\": \"$BUCKET_NAME\"}"
fi

SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --query 'ARN' --output text 2>/dev/null) || SECRET_ARN=""

if [ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ]; then
    log "Secret $SECRET_NAME already exists ($SECRET_ARN) — skipping creation"
else
    log "Creating secret $SECRET_NAME..."
    SECRET_ARN=$(aws secretsmanager create-secret \
        --name $SECRET_NAME \
        --description "Secrets for CDX" \
        --secret-string "$SECRET_STRING" \
        --query 'ARN' \
        --output text)
    wait_for_secret $SECRET_NAME
fi

apply_secret_tags "$SECRET_ARN" "$TAGS_FILE"

# ============================================================================
# S3 BUCKET (idempotent — check before create)
# ============================================================================
log "Setting up S3 Bucket..."

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    log "S3 bucket $BUCKET_NAME already exists — skipping creation"
else
    log "Creating S3 bucket $BUCKET_NAME..."
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
fi

apply_tags_alt "$BUCKET_NAME" "$TAGS_FILE" "s3api"

# ============================================================================
# ECS CLUSTER (idempotent — check before create)
# ============================================================================
log "Setting up ECS Cluster..."

ECS_CLUSTER_ARN=$(aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME \
    --query "clusters[?status=='ACTIVE'].clusterArn | [0]" --output text 2>/dev/null) || ECS_CLUSTER_ARN=""

if [ -n "$ECS_CLUSTER_ARN" ] && [ "$ECS_CLUSTER_ARN" != "None" ] && [ "$ECS_CLUSTER_ARN" != "" ]; then
    log "ECS Cluster $ECS_CLUSTER_NAME already exists — skipping"
else
    log "Creating ECS Cluster $ECS_CLUSTER_NAME..."
    ECS_CLUSTER_ARN=$(aws ecs create-cluster \
        --cluster-name $ECS_CLUSTER_NAME \
        --capacity-providers FARGATE FARGATE_SPOT \
        --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
        --query 'cluster.clusterArn' \
        --output text)
fi

apply_ecs_tags "$ECS_CLUSTER_ARN" "$ECS_CLUSTER_NAME" "$TAGS_FILE"

# ============================================================================
# SECURITY GROUP (idempotent — check before create)
# ============================================================================
log "Setting up Security Group..."

ECS_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) || ECS_SG_ID=""

if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
    log "Security group ${PROJECT_NAME}-ecs-sg already exists ($ECS_SG_ID) — skipping"
else
    SG_TAG_SPEC=$(generate_tag_specs "security-group" "$TAGS_FILE")
    log "Creating Security Group..."
    ECS_SG_ID=$(aws ec2 create-security-group \
        --group-name "${PROJECT_NAME}-ecs-sg" \
        --description "Security group for ECS cluster" \
        --vpc-id $VPC_ID \
        --tag-specifications "$SG_TAG_SPEC" \
        --query 'GroupId' \
        --output text)

    # Add internal communication rules
    aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 6032 --source-group $ECS_SG_ID
    aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 6033 --source-group $ECS_SG_ID
    aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 8079 --source-group $ECS_SG_ID
    aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 2049 --source-group $ECS_SG_ID
    aws ec2 authorize-security-group-egress --group-id $ECS_SG_ID --protocol tcp --port 2049 --source-group $ECS_SG_ID

    if [ "$ENABLE_DAM" = true ]; then
        log "Adding DAM security group rules..."
        aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 5432 --source-group $ECS_SG_ID
        aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 8080 --source-group $ECS_SG_ID
        aws ec2 authorize-security-group-egress --group-id $ECS_SG_ID --protocol tcp --port 5432 --source-group $ECS_SG_ID
    fi
fi

# ============================================================================
# EFS FILE SYSTEM (idempotent — check before create)
# ============================================================================
log "Setting up EFS file system..."

EFS_ID=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" \
    --output text 2>/dev/null) || EFS_ID=""

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    log "EFS ${PROJECT_NAME}-efs already exists ($EFS_ID) — skipping creation"
else
    log "Creating EFS file system..."
    EFS_TAGS=$(generate_efs_tags "efs" "$TAGS_FILE")
    EFS_ID=$(aws efs create-file-system \
        --performance-mode generalPurpose \
        --throughput-mode bursting \
        --encrypted \
        --tags "$EFS_TAGS" \
        --query 'FileSystemId' \
        --output text)

    log "Waiting for EFS to be available..."
    while true; do
        STATUS=$(aws efs describe-file-systems --file-system-id $EFS_ID \
            --query 'FileSystems[0].LifeCycleState' --output text)
        if [ "$STATUS" = "available" ]; then
            log "EFS is now available"
            break
        fi
        log "Waiting for EFS... Current status: $STATUS"
        sleep 10
    done
fi

# EFS Mount Targets (idempotent — check subnet before create)
log "Setting up EFS mount targets..."
EXISTING_MT_SUBNETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID \
    --query 'MountTargets[*].SubnetId' --output text 2>/dev/null) || EXISTING_MT_SUBNETS=""

if echo "$EXISTING_MT_SUBNETS" | grep -q "$PRIVATE_SUBNET_1_ID"; then
    log "Mount target in $PRIVATE_SUBNET_1_ID already exists — skipping"
else
    aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $PRIVATE_SUBNET_1_ID --security-groups $ECS_SG_ID
fi

if echo "$EXISTING_MT_SUBNETS" | grep -q "$PRIVATE_SUBNET_2_ID"; then
    log "Mount target in $PRIVATE_SUBNET_2_ID already exists — skipping"
else
    aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $PRIVATE_SUBNET_2_ID --security-groups $ECS_SG_ID
fi

# EFS Access Point (idempotent — check before create)
log "Setting up EFS access point..."
ACCESS_POINT_ID=$(aws efs describe-access-points --file-system-id $EFS_ID \
    --query "AccessPoints[?RootDirectory.Path=='/proxysql-data'].AccessPointId | [0]" \
    --output text 2>/dev/null) || ACCESS_POINT_ID=""

if [ -n "$ACCESS_POINT_ID" ] && [ "$ACCESS_POINT_ID" != "None" ]; then
    log "EFS access point already exists ($ACCESS_POINT_ID) — skipping"
else
    log "Creating EFS access point..."
    ACCESS_POINT_ID=$(aws efs create-access-point \
        --file-system-id $EFS_ID \
        --posix-user Uid=1000,Gid=1000 \
        --root-directory "Path=/proxysql-data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=777}" \
        --query 'AccessPointId' \
        --output text)
fi

# ============================================================================
# ECR TAGGING (idempotent — tagging is always safe to re-apply)
# ============================================================================
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")

if [ "$ENABLE_DAM" = true ]; then
    REPOSITORIES+=("cloudanix/ecr-aws-jit-dam-server" "cloudanix/ecr-aws-jit-postgresql")
fi

log "Tagging ECR repositories..."
for repo in "${REPOSITORIES[@]}"; do
    REPO_ARN=$(aws ecr describe-repositories --repository-names "$repo" \
        --query 'repositories[0].repositoryArn' --output text 2>/dev/null) || REPO_ARN=""

    if [ -n "$REPO_ARN" ] && [ "$REPO_ARN" != "None" ]; then
        apply_ecr_tags "$REPO_ARN" "$repo" "$TAGS_FILE" || \
            log "Warning: Failed to tag ECR repository $repo"
        log "Tagged ECR repository: $repo"
    else
        log "Warning: Repository $repo not found! Skipping."
    fi
done

# ============================================================================
# TASK DEFINITIONS (idempotent — register creates new revision, harmless)
# ============================================================================
if [ -n "$TAGS_FILE" ]; then
    TASK_TAGS=$(generate_task_tags "$TAGS_FILE")
else
    TASK_TAGS='[{"key":"Purpose","value":"database-iam-jit"},{"key":"created_by","value":"cloudanix"}]'
fi

# ProxyServer task definition
cat <<EOF > "proxyserver-task-definition.json"
{
    "family": "proxyserver-task",
    "containerDefinitions": [
        {
            "name": "proxyserver",
            "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudanix/ecr-aws-jit-proxy-server:latest",
            "cpu": 0,
            "portMappings": [
                {
                    "name": "proxyserver-http",
                    "containerPort": 8079,
                    "hostPort": 8079,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "AWS_DEFAULT_REGION",
                    "value": "$AWS_REGION"
                },
                {
                    "name": "PROXYSQL_HOST",
                    "value": "proxysql"
                }
            ],
            "secrets": [
                {
                    "name": "CDX_AUTH_TOKEN",
                    "valueFrom": "$SECRET_ARN:CDX_AUTH_TOKEN::"
                },
                {
                    "name": "CDX_SIGNATURE_SECRET_KEY",
                    "valueFrom": "$SECRET_ARN:CDX_SIGNATURE_SECRET_KEY::"
                },
                {
                    "name": "CDX_SENTRY_DSN",
                    "valueFrom": "$SECRET_ARN:CDX_SENTRY_DSN::"
                },
                {
                    "name": "CDX_DC",
                    "valueFrom": "$SECRET_ARN:CDX_DC::"
                },
                {
                    "name": "CDX_API_BASE",
                    "valueFrom": "$SECRET_ARN:CDX_API_BASE::"
                },
                {
                    "name": "CDX_LOGGING_S3_BUCKET",
                    "valueFrom": "$SECRET_ARN:CDX_LOGGING_S3_BUCKET::"
                }
EOF

if [ "$ENABLE_DAM" = true ]; then
    cat <<EOF >> "proxyserver-task-definition.json"
                ,
                {
                    "name": "POSTGRES_PASSWORD",
                    "valueFrom": "$SECRET_ARN:POSTGRES_PASSWORD::"
                }
                ,
                {
                    "name": "ENCRYPTION_KEY",
                    "valueFrom": "$SECRET_ARN:ENCRYPTION_KEY::"
                }
EOF
fi

cat <<EOF >> "proxyserver-task-definition.json"
            ],
            "mountPoints": [
                {
                    "sourceVolume": "proxysql-data",
                    "containerPath": "/var/lib/proxysql",
                    "readOnly": false
                }
            ],
            "volumesFrom": [],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${PROJECT_NAME}/proxyserver",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "systemControls": []
        }
    ],
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "networkMode": "awsvpc",
    "volumes": [
        {
            "name": "proxysql-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "$EFS_ID",
                "rootDirectory": "/",
                "transitEncryption": "ENABLED",
                "transitEncryptionPort": 2049,
                "authorizationConfig": {
                    "accessPointId": "$ACCESS_POINT_ID",
                    "iam": "ENABLED"
                }
            }
        }
    ],
    "placementConstraints": [],
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "256",
    "memory": "1024",
    "tags": $TASK_TAGS
}
EOF

# ProxySQL task definition
cat <<EOF > "proxysql-task-definition.json"
{
    "family": "proxysql",
    "containerDefinitions": [
        {
            "name": "proxysql",
            "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudanix/ecr-aws-jit-proxy-sql:latest",
            "cpu": 0,
            "portMappings": [
                {
                    "name": "proxysql-admin",
                    "containerPort": 6032,
                    "hostPort": 6032,
                    "protocol": "tcp"
                },
                {
                    "name": "proxysql-mysql",
                    "containerPort": 6033,
                    "hostPort": 6033,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [],
            "mountPoints": [
                {
                    "sourceVolume": "proxysql-data",
                    "containerPath": "/var/lib/proxysql",
                    "readOnly": false
                }
            ],
            "volumesFrom": [],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${PROJECT_NAME}/proxysql",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "systemControls": []
        }
    ],
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "networkMode": "awsvpc",
    "volumes": [
        {
            "name": "proxysql-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "$EFS_ID",
                "rootDirectory": "/",
                "transitEncryption": "ENABLED",
                "transitEncryptionPort": 2049,
                "authorizationConfig": {
                    "accessPointId": "$ACCESS_POINT_ID",
                    "iam": "ENABLED"
                }
            }
        }
    ],
    "placementConstraints": [],
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "256",
    "memory": "1024",
    "tags": $TASK_TAGS
}
EOF

# Query Logging task definition
cat <<EOF > "query-logging-task-definition.json"
{
    "family": "query-logging-task",
    "containerDefinitions": [
        {
            "name": "query-logging",
            "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudanix/ecr-aws-jit-query-logging:latest",
            "cpu": 0,
            "portMappings": [
                {
                    "name": "query-logging-port",
                    "containerPort": 8079,
                    "hostPort": 8079,
                    "protocol": "tcp",
                    "appProtocol": "http"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "AWS_DEFAULT_REGION",
                    "value": "$AWS_REGION"
                },
                {
                    "name": "CDX_APP_ENV",
                    "value": "production"
                },
                {
                    "name": "CDX_LOG_LEVEL",
                    "value": "DEBUG"
                },
                {
                    "name": "CDX_DEFAULT_REGION",
                    "value": "$AWS_REGION"
                },
                {
                    "name": "CDX_SERVER_VERSION",
                    "value": "1.0.0"
                }
            ],
            "mountPoints": [
                {
                    "sourceVolume": "proxysql-data",
                    "containerPath": "/var/lib/proxysql",
                    "readOnly": false
                }
            ],
            "volumesFrom": [],
            "secrets": [
                {
                    "name": "CDX_AUTH_TOKEN",
                    "valueFrom": "$SECRET_ARN:CDX_AUTH_TOKEN::"
                },
                {
                    "name": "CDX_SIGNATURE_SECRET_KEY",
                    "valueFrom": "$SECRET_ARN:CDX_SIGNATURE_SECRET_KEY::"
                },
                {
                    "name": "CDX_SENTRY_DSN",
                    "valueFrom": "$SECRET_ARN:CDX_SENTRY_DSN::"
                },
                {
                    "name": "CDX_DC",
                    "valueFrom": "$SECRET_ARN:CDX_DC::"
                },
                {
                    "name": "CDX_API_BASE",
                    "valueFrom": "$SECRET_ARN:CDX_API_BASE::"
                },
                {
                    "name": "CDX_LOGGING_S3_BUCKET",
                    "valueFrom": "$SECRET_ARN:CDX_LOGGING_S3_BUCKET::"
                }
EOF

if [ "$ENABLE_DAM" = true ]; then
    cat <<EOF >> "query-logging-task-definition.json"
                ,
                {
                    "name": "POSTGRES_PASSWORD",
                    "valueFrom": "$SECRET_ARN:POSTGRES_PASSWORD::"
                },
                {
                    "name": "ENCRYPTION_KEY",
                    "valueFrom": "$SECRET_ARN:ENCRYPTION_KEY::"
                }
EOF
fi

cat <<EOF >> "query-logging-task-definition.json"
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${PROJECT_NAME}/query-logging",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "systemControls": []
        }
    ],
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "networkMode": "awsvpc",
    "volumes": [
        {
            "name": "proxysql-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "$EFS_ID",
                "rootDirectory": "/",
                "transitEncryption": "ENABLED",
                "transitEncryptionPort": 2049,
                "authorizationConfig": {
                    "accessPointId": "$ACCESS_POINT_ID",
                    "iam": "ENABLED"
                }
            }
        }
    ],
    "placementConstraints": [],
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "256",
    "memory": "1024",
    "tags": $TASK_TAGS
}
EOF

# DAM task definitions
if [ "$ENABLE_DAM" = true ]; then
    log "Creating DAM task definitions..."

    cat <<EOF > "dam-server-task-definition.json"
{
    "family": "dam-server-task",
    "containerDefinitions": [
        {
            "name": "dam-server",
            "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudanix/ecr-aws-jit-dam-server:latest",
            "cpu": 0,
            "portMappings": [
                {
                    "name": "dam-server-http",
                    "containerPort": 8080,
                    "hostPort": 8080,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                { "name": "AWS_DEFAULT_REGION", "value": "$AWS_REGION" },
                { "name": "NODE_ENV", "value": "production" },
                { "name": "PROXYSERVER_HOST", "value": "proxyserver" },
                { "name": "PROXYSERVER_PORT", "value": "8079" },
                { "name": "DAM_LOG_LEVEL", "value": "INFO" },
                { "name": "DAM_APP_ENV", "value": "production" }
            ],
            "secrets": [
                { "name": "CDX_AUTH_TOKEN", "valueFrom": "$SECRET_ARN:CDX_AUTH_TOKEN::" },
                { "name": "CDX_SIGNATURE_SECRET_KEY", "valueFrom": "$SECRET_ARN:CDX_SIGNATURE_SECRET_KEY::" },
                { "name": "CDX_SENTRY_DSN", "valueFrom": "$SECRET_ARN:CDX_SENTRY_DSN::" },
                { "name": "CDX_DC", "valueFrom": "$SECRET_ARN:CDX_DC::" },
                { "name": "CDX_API_BASE", "valueFrom": "$SECRET_ARN:CDX_API_BASE::" },
                { "name": "POSTGRES_PASSWORD", "valueFrom": "$SECRET_ARN:POSTGRES_PASSWORD::" }
            ],
            "mountPoints": [
                { "sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false }
            ],
            "volumesFrom": [],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${PROJECT_NAME}/dam-server",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "systemControls": []
        }
    ],
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "networkMode": "awsvpc",
    "volumes": [
        {
            "name": "proxysql-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "$EFS_ID",
                "rootDirectory": "/",
                "transitEncryption": "ENABLED",
                "transitEncryptionPort": 2049,
                "authorizationConfig": { "accessPointId": "$ACCESS_POINT_ID", "iam": "ENABLED" }
            }
        }
    ],
    "placementConstraints": [],
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "tags": $TASK_TAGS
}
EOF

    cat <<EOF > "postgresql-task-definition.json"
{
    "family": "postgresql-task",
    "containerDefinitions": [
        {
            "name": "postgresql",
            "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudanix/ecr-aws-jit-postgresql:latest",
            "cpu": 0,
            "portMappings": [
                { "name": "postgresql-db", "containerPort": 5432, "hostPort": 5432, "protocol": "tcp" }
            ],
            "essential": true,
            "environment": [
                { "name": "POSTGRES_USER", "value": "pgjitdbuser" },
                { "name": "POSTGRES_DB", "value": "jitdb" },
                { "name": "PGDATA", "value": "/var/lib/proxysql/postgresql/data/pgdata" },
                { "name": "POSTGRES_INITDB_ARGS", "value": "-E UTF8 --locale=en_US.utf8" }
            ],
            "secrets": [
                { "name": "POSTGRES_PASSWORD", "valueFrom": "$SECRET_ARN:POSTGRES_PASSWORD::" }
            ],
            "mountPoints": [
                { "sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false }
            ],
            "volumesFrom": [],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${PROJECT_NAME}/postgresql",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "healthCheck": {
                "command": ["CMD-SHELL", "pg_isready -U pgjitdbuser -d jitdb || exit 1"],
                "interval": 30,
                "timeout": 5,
                "retries": 3,
                "startPeriod": 60
            },
            "systemControls": []
        }
    ],
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/cdx-ECSTaskRole",
    "networkMode": "awsvpc",
    "volumes": [
        {
            "name": "proxysql-data",
            "efsVolumeConfiguration": {
                "fileSystemId": "$EFS_ID",
                "rootDirectory": "/",
                "transitEncryption": "ENABLED",
                "transitEncryptionPort": 2049,
                "authorizationConfig": { "accessPointId": "$ACCESS_POINT_ID", "iam": "ENABLED" }
            }
        }
    ],
    "placementConstraints": [],
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "tags": $TASK_TAGS
}
EOF
fi

log "Registering Task Definitions..."
aws ecs register-task-definition --cli-input-json file://proxyserver-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text
aws ecs register-task-definition --cli-input-json file://proxysql-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text
aws ecs register-task-definition --cli-input-json file://query-logging-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text

if [ "$ENABLE_DAM" = true ]; then
    log "Registering DAM task definitions..."
    aws ecs register-task-definition --cli-input-json file://dam-server-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text
    aws ecs register-task-definition --cli-input-json file://postgresql-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text
fi

# ============================================================================
# SERVICE CONNECT NAMESPACE (idempotent — already had check)
# ============================================================================
log "Setting up Service Connect namespace..."
if ! aws servicediscovery list-namespaces --query "Namespaces[?Name=='proxysql-proxyserver']" --output text | grep -q 'ns-'; then
    aws servicediscovery create-private-dns-namespace \
        --name proxysql-proxyserver \
        --vpc $VPC_ID \
        --region $AWS_REGION
fi
wait_for_namespace "proxysql-proxyserver"

NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --query 'Namespaces[?Name==`proxysql-proxyserver`].Id' \
    --output text)

# ============================================================================
# ECS SERVICES (idempotent — check before create)
# ============================================================================
if [ -n "$TAGS_FILE" ]; then
    SERVICE_TAGS=$(generate_ecs_service_tags "$TAGS_FILE")
else
    SERVICE_TAGS="key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
fi

log "Setting up ECS Services..."

create_service_if_not_exists "proxysql" \
    --cluster $ECS_CLUSTER_NAME \
    --service-name proxysql \
    --task-definition proxysql \
    --tags $SERVICE_TAGS \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "proxysql-proxyserver",
        "services": [{
            "portName": "proxysql-admin",
            "discoveryName": "proxysql",
            "clientAliases": [{
                "port": 6032,
                "dnsName": "proxysql"
            }]
        }]
    }'

create_service_if_not_exists "proxyserver" \
    --cluster $ECS_CLUSTER_NAME \
    --service-name proxyserver \
    --task-definition proxyserver-task \
    --tags $SERVICE_TAGS \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "proxysql-proxyserver",
        "services": [{
            "portName": "proxyserver-http",
            "discoveryName": "proxyserver",
            "clientAliases": [{
                "port": 8079,
                "dnsName": "proxyserver"
            }]
        }]
    }'

create_service_if_not_exists "query-logging" \
    --cluster $ECS_CLUSTER_NAME \
    --service-name query-logging \
    --task-definition query-logging-task \
    --tags $SERVICE_TAGS \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "proxysql-proxyserver",
        "services": []
    }'

if [ "$ENABLE_DAM" = true ]; then
    log "Setting up DAM services..."

    create_service_if_not_exists "postgresql" \
        --cluster $ECS_CLUSTER_NAME \
        --service-name postgresql \
        --task-definition postgresql-task \
        --tags $SERVICE_TAGS \
        --desired-count 1 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
        --enable-execute-command \
        --service-connect-configuration '{
            "enabled": true,
            "namespace": "proxysql-proxyserver",
            "services": [{
                "portName": "postgresql-db",
                "discoveryName": "postgresql",
                "clientAliases": [{
                    "port": 5432,
                    "dnsName": "postgresql"
                }]
            }]
        }'

    log "Waiting for PostgreSQL service to stabilize..."
    aws ecs wait services-stable --cluster $ECS_CLUSTER_NAME --services postgresql || log "Warning: PostgreSQL not yet stable"

    create_service_if_not_exists "dam-server" \
        --cluster $ECS_CLUSTER_NAME \
        --service-name dam-server \
        --task-definition dam-server-task \
        --tags $SERVICE_TAGS \
        --desired-count 1 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
        --enable-execute-command \
        --service-connect-configuration '{
            "enabled": true,
            "namespace": "proxysql-proxyserver",
            "services": [{
                "portName": "dam-server-http",
                "discoveryName": "dam-server",
                "clientAliases": [{
                    "port": 8080,
                    "dnsName": "dam-server"
                }]
            }]
        }'
fi

# Wait for services to be stable
log "Waiting for core services to be stable..."
aws ecs wait services-stable --cluster $ECS_CLUSTER_NAME --services proxysql proxyserver query-logging || log "Warning: Some services not yet stable"

if [ "$ENABLE_DAM" = true ]; then
    log "Waiting for DAM services to be stable..."
    aws ecs wait services-stable --cluster $ECS_CLUSTER_NAME --services dam-server || log "Warning: DAM service not yet stable"
fi

echo "ECS services setup complete!"

# Create infrastructure details file
cat << EOF > infrastructure-details.txt
Infrastructure Details
---------------------
VPC ID: $VPC_ID
ECS Cluster: $ECS_CLUSTER_NAME
Security Group: $ECS_SG_ID
Private Subnet 1: $PRIVATE_SUBNET_1_ID
Private Subnet 2: $PRIVATE_SUBNET_2_ID
Public Subnet 1: $PUBLIC_SUBNET_1_ID
Public Subnet 2: $PUBLIC_SUBNET_2_ID
EFS File System: $EFS_ID
EFS Access Point: $ACCESS_POINT_ID
S3 Bucket: $BUCKET_NAME
Secrets Manager: $SECRET_NAME
Service Connect Namespace: proxysql-proxyserver ($NAMESPACE_ID)

Services Created:
- proxysql
- proxyserver
- query-logging
EOF

if [ "$ENABLE_DAM" = true ]; then
    cat << EOF >> infrastructure-details.txt
- postgresql
- dam-server
EOF
fi

log "Infrastructure details saved to infrastructure-details.txt"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Infrastructure Summary:"
echo "  VPC: $VPC_ID"
echo "  Cluster: $ECS_CLUSTER_NAME"
echo "  EFS: $EFS_ID"
echo "  S3 Bucket: $BUCKET_NAME"
echo "  DAM Enabled: $ENABLE_DAM"
echo ""

ENABLE_UPDATE_SERVICES=false
if prompt_yes_no "Are you updating images in Cluster" "n"; then
    ENABLE_UPDATE_SERVICES=true
    echo "ECS will be updated"
else
    echo "ECS will not be updated"
fi

if [ "$ENABLE_UPDATE_SERVICES" = true ]; then
    ECS_SERVICES=("proxysql" "query-logging" "proxyserver")

    if [ "$ENABLE_DAM" = true ]; then
        ECS_SERVICES+=("dam-server" "postgresql")
    fi

    for ECS_SERVICE in "${ECS_SERVICES[@]}"; do
        echo "Updating ecs service: $ECS_SERVICE"
        aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE" \
            --force-new-deployment --region "$AWS_REGION" --output text > /dev/null
        sleep 10
    done

    echo "Services Updated for all ECS Services."
fi
