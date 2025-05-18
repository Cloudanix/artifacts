#!/bin/bash
set -e  
set -u  


prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code"
    # Additional cleanup could be added here
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
    
    # Poll for the secret's existence using describe-secret
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
        # Convert the Tags array format from ResourceType format to key/value format for task definitions
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
        # Convert JSON array to CLI format for ECS service tags
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
        # For S3, the format is {"TagSet": [{"Key":"k1", "Value":"v1"}, ...]}
        local tag_set=$(jq -c '{TagSet: .}' "$tags_file")
        aws $service put-bucket-tagging --bucket "$resource_name" --tagging "$tag_set"
    else
        aws $service put-bucket-tagging --bucket "$resource_name" --tagging "$default_tags"
    fi
}

# Function to apply tags to logs
apply_logs_tags() {
    local log_group_name=$1
    local tags_file=$2
    local default_tags='{"Purpose": "database-iam-jit", "created_by": "cloudanix"}'
    
    if [ -f "$tags_file" ]; then
        # Convert JSON array to object format for logs
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
        # Read and use tags from the provided JSON file
        tags_json=$(jq -c '.' "$tags_file")
    else
        # Use default tags
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
        # Read JSON tags, but override or add the Name tag dynamically
        tags_json=$(jq --arg name "$repo_name" '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]
        ' "$tags_file" | jq -c '.')
    else
        # Use default tags including dynamic Name
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
        # Add or override Name tag and convert to CLI format
        tag_params=$(jq --arg name "$cluster_name" -r '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}] |
            .[] | "key=\(.Key),value=\(.Value)"
        ' "$tags_file" | tr '\n' ' ')
    else
        # Default tags in CLI format
        tag_params="key=Name,value=$cluster_name key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
    fi

    aws ecs tag-resource \
        --resource-arn "$resource_arn" \
        --tags $tag_params
}
generate_efs_tags() {
    local resource_type=$1  # just used for naming
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

echo "=== JIT Account Infrastructure Setup ==="
echo "Please provide the following configuration details:"
# AWS Configuration
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $ACCOUNT_ID"
# Project Configuration
PROJECT_NAME="cdx-jit-db"
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
# Secrets Configuration
SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name" "CDX_SECRETS")
CDX_AUTH_TOKEN=$(prompt_with_default "CDX Auth Token" "AUTH_TOKEN_1234567890")
CDX_SIGNATURE_SECRET_KEY=$(prompt_with_default "CDX Signature Secret Key" "SECRET_1234567890")
CDX_SENTRY_DSN=$(prompt_with_default "CDX Sentry DSN" "CDX_SENTRY_DSN")
CDX_DC=$(prompt_with_default "CDX_DC" "US")
CDX_API_BASE=$(prompt_with_default "CDX_API_BASE" "https://console.cloudanix.com")
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
if [ -n "$TAGS_FILE" ]; then
    echo "Using custom tags from: $TAGS_FILE"
else
    echo "Using default tags"
fi

# Create ECS Service Linked Role if it doesn't exist
log "Creating ECS Service Linked Role..."
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com || true

log "Creating ECS Task Role and policies..."

ECS_TASK_ROLE_NAME="cdx-ECSTaskRole"
# Create the ECS task role
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

# Create custom policy for Secrets Manager access
aws iam create-policy \
    --policy-name cdx-ECSSecretsAccessPolicy \
    --policy-document '{
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

# Create custom policy for RDS role assumption
aws iam create-policy \
    --policy-name cdx-ECSRDSAssumeRolePolicy \
    --policy-document '{
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

# Create EFS access policy
log "Creating EFS access policy..."
aws iam create-policy \
    --policy-name cdx-EFSAccessPolicy \
    --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:DescribeMountTargets"
            ],
            "Resource": "arn:aws:elasticfilesystem:'$AWS_REGION':'$ACCOUNT_ID':file-system/*"
        }
    ]
}'

log "Creating custom S3 policy..."
S3_POLICY_NAME="cdx-S3AccessPolicy"

aws iam create-policy \
    --policy-name $S3_POLICY_NAME \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:*",
                    "s3-object-lambda:*"
                ],
                "Resource": [
                    "arn:aws:s3:::'$BUCKET_NAME'",
                    "arn:aws:s3:::'$BUCKET_NAME'/*"
                ]
            }
        ]
    }'

log "Creating custom CloudWatch Logs policy..."
LOGS_POLICY_NAME="cdx-CloudWatchLogsPolicy"

aws iam create-policy \
    --policy-name $LOGS_POLICY_NAME \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "logs:*",
                    "cloudwatch:GenerateQuery"
                ],
                "Resource": [
                    "arn:aws:logs:'$AWS_REGION':'$ACCOUNT_ID':log-group:'$LOG_GROUP_NAME_1':*",
                    "arn:aws:logs:'$AWS_REGION':'$ACCOUNT_ID':log-group:'$LOG_GROUP_NAME_2':*",
                    "arn:aws:logs:'$AWS_REGION':'$ACCOUNT_ID':log-group:'$LOG_GROUP_NAME_3':*"
                ]
            }
        ]
    }'

# Store policy ARNs in variables
SECRETS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-ECSSecretsAccessPolicy`].Arn' --output text)
RDS_ASSUME_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-ECSRDSAssumeRolePolicy`].Arn' --output text)
EFS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-EFSAccessPolicy`].Arn' --output text)
S3_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`'$S3_POLICY_NAME'`].Arn' --output text)
LOGS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`'$LOGS_POLICY_NAME'`].Arn' --output text)

# Attach AWS managed policies
aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

# Attach custom policies
aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn $SECRETS_POLICY_ARN

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn $RDS_ASSUME_POLICY_ARN

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn $EFS_POLICY_ARN

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn $S3_POLICY_ARN

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn $LOGS_POLICY_ARN
    
log "ECS Task Role and policies created successfully"

log "Creating CloudWatch Log Group..."
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_1
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_2
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_3

apply_logs_tags "$LOG_GROUP_NAME_1" "$TAGS_FILE"
apply_logs_tags "$LOG_GROUP_NAME_2" "$TAGS_FILE"
apply_logs_tags "$LOG_GROUP_NAME_3" "$TAGS_FILE"

log "Creating Secrets in Secret Manager ..."
SECRET_ARN=$(aws secretsmanager create-secret \
    --name $SECRET_NAME \
    --description "Secrets for CDX" \
    --secret-string "{\"CDX_AUTH_TOKEN\": \"$CDX_AUTH_TOKEN\", \"CDX_SIGNATURE_SECRET_KEY\": \"$CDX_SIGNATURE_SECRET_KEY\", \"CDX_SENTRY_DSN\": \"$CDX_SENTRY_DSN\", \"CDX_DC\": \"$CDX_DC\", \"CDX_API_BASE\": \"$CDX_API_BASE\", \"CDX_LOGGING_S3_BUCKET\": \"$BUCKET_NAME\"}" \
    --query 'ARN' \
    --output text)

wait_for_secret $SECRET_NAME

apply_secret_tags "$SECRET_ARN" "$TAGS_FILE"

# Create S3 Bucket 
echo "Creating S3 Bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION
apply_tags_alt "$BUCKET_NAME" "$TAGS_FILE" "s3api"

# Create ECS Cluster
log "Creating ECS Cluster..."
ECS_CLUSTER_ARN=$(aws ecs create-cluster \
    --cluster-name $ECS_CLUSTER_NAME \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --query 'cluster.clusterArn' \
    --output text)

apply_ecs_tags "$ECS_CLUSTER_ARN" "$ECS_CLUSTER_NAME" "$TAGS_FILE"

SG_TAG_SPEC=$(generate_tag_specs "security-group" "$TAGS_FILE")
# Create Security Group
log "Creating Security Group..."
ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-ecs-sg" \
    --description "Security group for ECS cluster" \
    --vpc-id $VPC_ID \
    --tag-specifications "$SG_TAG_SPEC" \
    --query 'GroupId' \
    --output text)

# Add internal communication rules for ECS tasks
aws ec2 authorize-security-group-ingress \
    --group-id $ECS_SG_ID \
    --protocol tcp \
    --port 6032 \
    --source-group $ECS_SG_ID

aws ec2 authorize-security-group-ingress \
    --group-id $ECS_SG_ID \
    --protocol tcp \
    --port 6033 \
    --source-group $ECS_SG_ID

aws ec2 authorize-security-group-ingress \
    --group-id $ECS_SG_ID \
    --protocol tcp \
    --port 8079 \
    --source-group $ECS_SG_ID

aws ec2 authorize-security-group-ingress \
    --group-id $ECS_SG_ID \
    --protocol tcp \
    --port 2049 \
    --source-group $ECS_SG_ID

aws ec2 authorize-security-group-egress \
    --group-id $ECS_SG_ID \
    --protocol tcp \
    --port 2049 \
    --source-group $ECS_SG_ID

# Create EFS file system
log "Creating EFS file system..."

# Create tags JSON for EFS using the function
EFS_TAGS=$(generate_efs_tags "efs" "$TAGS_FILE")

EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags "$EFS_TAGS" \
    --query 'FileSystemId' \
    --output text)

# Wait for EFS to be available
log "Waiting for EFS to be available..."
while true; do
    STATUS=$(aws efs describe-file-systems \
        --file-system-id $EFS_ID \
        --query 'FileSystems[0].LifeCycleState' \
        --output text)
    
    if [ "$STATUS" = "available" ]; then
        log "EFS is now available"
        break
    fi
    
    log "Waiting for EFS to become available... Current status: $STATUS"
    sleep 10
done

# Create mount targets in both private subnets
log "Creating EFS mount targets..."
aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $PRIVATE_SUBNET_1_ID \
    --security-groups $ECS_SG_ID

aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $PRIVATE_SUBNET_2_ID \
    --security-groups $ECS_SG_ID

# Create EFS access point
log "Creating EFS access point..."
ACCESS_POINT_ID=$(aws efs create-access-point \
    --file-system-id $EFS_ID \
    --posix-user Uid=1000,Gid=1000 \
    --root-directory "Path=/proxysql-data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=777}" \
    --query 'AccessPointId' \
    --output text)

REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")


log "Tagging specified ECR repositories..."
for repo in "${REPOSITORIES[@]}"; do
    REPO_ARN=$(aws ecr describe-repositories --repository-names "$repo" \
        --query 'repositories[0].repositoryArn' --output text 2>/dev/null)

    if [ -n "$REPO_ARN" ] && [ "$REPO_ARN" != "None" ]; then
        apply_ecr_tags "$REPO_ARN" "$repo" "$TAGS_FILE" || \
            log "Warning: Failed to tag ECR repository $repo"
        log "Tagged ECR repository: $repo"
    else
        log "Warning: Repository $repo not found!"
    fi
done

# Get task tags
if [ -n "$TAGS_FILE" ]; then
    TASK_TAGS=$(generate_task_tags "$TAGS_FILE")
else
    TASK_TAGS='[{"key":"Purpose","value":"database-iam-jit"},{"key":"created_by","value":"cloudanix"}]'
fi

cat <<EOF >  "proxyserver-task-definition.json"
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
    "cpu": "2048",
    "memory": "4096",
    "tags": $TASK_TAGS
}
EOF

cat <<EOF >  "proxysql-task-definition.json"
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
    "cpu": "2048",
    "memory": "4096",
    "tags": $TASK_TAGS
}
EOF

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
                    "name": "CDX_DC",
                    "valueFrom": "$SECRET_ARN:CDX_DC::"
                },
                {
                    "name": "CDX_LOGGING_S3_BUCKET",
                    "valueFrom": "$SECRET_ARN:CDX_LOGGING_S3_BUCKET::"
                },
                {
                    "name": "CDX_SENTRY_DSN",
                    "valueFrom": "$SECRET_ARN:CDX_SENTRY_DSN::"
                }
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
   "cpu": "1024",
    "memory": "2048",
    "tags": $TASK_TAGS
}
EOF


log "Registering Task Definitions..."
TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://proxyserver-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://proxysql-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://query-logging-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)

# Create Service Connect namespace
log "Creating Service Connect namespace..."
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


# Get service tags
if [ -n "$TAGS_FILE" ]; then
    SERVICE_TAGS=$(generate_ecs_service_tags "$TAGS_FILE")
else
    SERVICE_TAGS="key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
fi

# Create ECS Services
log "Creating ECS Services..."
# Create ProxySQL service
aws ecs create-service \
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

# Create ProxyServer service
aws ecs create-service \
    --cluster $ECS_CLUSTER_NAME \
    --service-name proxyserver \
    --task-definition proxyserver-task \
    --tags $SERVICE_TAGS \
    --desired-count 2 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "proxysql-proxyserver",
        "services": []
    }'

log "Creating query-logging service..."
aws ecs create-service \
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

# Wait for services to be stable
log "Waiting for services to be stable..."

aws ecs wait services-stable \
    --cluster $ECS_CLUSTER_NAME \
    --services proxysql proxyserver


echo "ECS services setup complete!"

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
EOF