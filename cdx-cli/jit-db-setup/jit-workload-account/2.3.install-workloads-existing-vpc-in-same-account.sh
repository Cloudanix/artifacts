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

# Function to check if IAM role exists
check_role_exists() {
    local role_name=$1
    
    log "Checking if IAM role ${role_name} exists..."
    if aws iam get-role --role-name "${role_name}" --query "Role.RoleName" --output text 2>/dev/null | grep -q "${role_name}"; then
        log "IAM role ${role_name} exists."
        return 0
    else
        log "IAM role ${role_name} does not exist."
        return 1
    fi
}

# === Extend IAM Policies with New Resources ===

extend_policy() {
  local policy_name=$1
  shift
  local new_resources=("$@")
  local policy_arn="arn:aws:iam::$ACCOUNT_ID:policy/$policy_name"

  log "Extending IAM policy: $policy_name"

  version_id=$(aws iam get-policy --policy-arn $policy_arn --query 'Policy.DefaultVersionId' --output text)

  aws iam get-policy-version \
    --policy-arn $policy_arn \
    --version-id $version_id \
    --query 'PolicyVersion.Document' \
    --output json > tmp-policy.json

  jq --argjson newResources "$(printf '%s\n' "${new_resources[@]}" | jq -R . | jq -s .)" \
    '(.Statement[0].Resource) |= (. + $newResources | unique)' \
    tmp-policy.json > updated-policy.json

  version_count=$(aws iam list-policy-versions --policy-arn $policy_arn --query 'Versions' | jq length)
  if [ "$version_count" -ge 5 ]; then
    old_version=$(aws iam list-policy-versions --policy-arn $policy_arn \
      --query 'Versions[?IsDefaultVersion==`false`].[VersionId]' \
      --output text | head -n 1)
    aws iam delete-policy-version --policy-arn $policy_arn --version-id $old_version
    log "Deleted old policy version: $old_version"
  fi

  aws iam create-policy-version \
    --policy-arn $policy_arn \
    --policy-document file://updated-policy.json \
    --set-as-default > /dev/null

  rm -f tmp-policy.json updated-policy.json
  log "Updated policy: $policy_name with new resources."
}

echo "=== JIT Account Infrastructure Setup - Additional VPC ==="
echo "Please provide the following configuration details:"

# AWS Configuration
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
SETUP_NUMBER=$(prompt_with_default "Enter the setup number for this deployment in this account " "2")
echo "Your AWS Account ID is: $ACCOUNT_ID"
PROJECT_NAME="cdx-jit-db"
NAMESPACE_NAME="proxysql-proxyserver-${SETUP_NUMBER}"
VPC_ID=$(prompt_with_default "VPC ID for this setup" "vpc-xxxxxxxx")
PRIVATE_SUBNET_1_ID=$(prompt_with_default "Private Subnet 1 ID" "subnet-xxxxxxxx")
PRIVATE_SUBNET_2_ID=$(prompt_with_default "Private Subnet 2 ID" "subnet-xxxxxxxx")
PUBLIC_SUBNET_1_ID=$(prompt_with_default "Public Subnet 1 ID" "subnet-xxxxxxxx")
PUBLIC_SUBNET_2_ID=$(prompt_with_default "Public Subnet 2 ID" "subnet-xxxxxxxx")

# Bucket details - using different bucket name for log storage
BUCKET_NAME=$(prompt_with_default "Enter unique S3 bucket name according to cdx-jit-db-logs-<org_name> pattern" "cdx-jit-db-logs")

# ECS Configuration with unique names
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster-${SETUP_NUMBER}"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver-${SETUP_NUMBER}"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql-${SETUP_NUMBER}"
LOG_GROUP_NAME_3="/ecs/${PROJECT_NAME}/query-logging-${SETUP_NUMBER}"

# Secrets Configuration
SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name" "CDX_SECRETS")
CDX_AUTH_TOKEN=$(prompt_with_default "CDX Auth Token" "AUTH_TOKEN_1234567890")
CDX_SIGNATURE_SECRET_KEY=$(prompt_with_default "CDX Signature Secret Key" "SECRET_1234567890")
CDX_SENTRY_DSN=$(prompt_with_default "CDX Sentry DSN" "CDX_SENTRY_DSN")
CDX_DC=$(prompt_with_default "CDX_DC" "US")
CDX_API_BASE=$(prompt_with_default "CDX_API_BASE" "https://console.cloudanix.com")

log "Creating Secrets in Secret Manager ..."
SECRET_ARN=$(aws secretsmanager create-secret \
    --name $SECRET_NAME \
    --description "Secrets for CDX" \
    --secret-string "{\"CDX_AUTH_TOKEN\": \"$CDX_AUTH_TOKEN\", \"CDX_SIGNATURE_SECRET_KEY\": \"$CDX_SIGNATURE_SECRET_KEY\", \"CDX_SENTRY_DSN\": \"$CDX_SENTRY_DSN\", \"CDX_DC\": \"$CDX_DC\", \"CDX_API_BASE\": \"$CDX_API_BASE\", \"CDX_LOGGING_S3_BUCKET\": \"$BUCKET_NAME\"}" \
    --query 'ARN' \
    --output text)

wait_for_secret $SECRET_NAME

aws secretsmanager tag-resource \
    --secret-id $SECRET_NAME \
    --tags '[{"Key":"Purpose","Value":"database-iam-jit"},{"Key":"created_by","Value":"cloudanix"}]'
echo "Secret created with ARN: $SECRET_ARN"

echo -e "\n=== Configuration Summary ==="
echo "AWS Region: $AWS_REGION"
echo "Setup Number: $SETUP_NUMBER"
echo "Project Name: $PROJECT_NAME"
echo "ECS Cluster Name: $ECS_CLUSTER_NAME"
echo "Secrets Name: $SECRET_NAME"
echo "VPC ID: $VPC_ID"

# Create ECS Service Linked Role if it doesn't exist
log "Ensuring ECS Service Linked Role exists..."
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

# Create CloudWatch Log Groups
log "Creating CloudWatch Log Groups..."
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_1 || true
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_2 || true
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_3 || true

# Add tags to log groups
aws logs tag-log-group \
    --log-group-name $LOG_GROUP_NAME_1 \
    --tags '{"Purpose": "database-iam-jit", "created_by": "cloudanix", "setup": "'$SETUP_NUMBER'"}'

aws logs tag-log-group \
    --log-group-name $LOG_GROUP_NAME_2 \
    --tags '{"Purpose": "database-iam-jit", "created_by": "cloudanix", "setup": "'$SETUP_NUMBER'"}'

aws logs tag-log-group \
    --log-group-name $LOG_GROUP_NAME_3 \
    --tags '{"Purpose": "database-iam-jit", "created_by": "cloudanix", "setup": "'$SETUP_NUMBER'"}'

# Create S3 Bucket for this setup
log "Creating S3 Bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION || log "Bucket may already exist, continuing..."

aws s3api put-bucket-tagging \
    --bucket $BUCKET_NAME \
    --tagging '{"TagSet": [{"Key": "Purpose", "Value": "database-iam-jit"}, {"Key": "created_by", "Value": "cloudanix"}, {"Key": "setup", "Value": "'$SETUP_NUMBER'"}]}'

# Define new resources for this setup
S3_RESOURCES=(
  "arn:aws:s3:::$BUCKET_NAME"
  "arn:aws:s3:::$BUCKET_NAME/*"
)

LOG_RESOURCES=(
  "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_1:*"
  "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_2:*"
  "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$LOG_GROUP_NAME_3:*"
)

# Extend both policies
extend_policy cdx-S3AccessPolicy "${S3_RESOURCES[@]}"
extend_policy cdx-CloudWatchLogsPolicy "${LOG_RESOURCES[@]}"

log "IAM policy extension for setup #${SETUP_NUMBER} is complete."

# Create ECS Cluster
log "Creating ECS Cluster..."
aws ecs create-cluster \
    --cluster-name $ECS_CLUSTER_NAME \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER

# Create Security Group
SG_NAME="${PROJECT_NAME}-ecs-sg-${SETUP_NUMBER}"
log "Creating Security Group: $SG_NAME..."
ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for ECS cluster setup $SETUP_NUMBER" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value='$SG_NAME'},{Key=Purpose,Value=database-iam-jit},{Key=created_by,Value=cloudanix},{Key=setup,Value='$SETUP_NUMBER'}]' \
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
EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags '[{"Key":"Name","Value":"'${PROJECT_NAME}'-efs-'${SETUP_NUMBER}'"}, {"Key":"Purpose","Value":"database-iam-jit"}, {"Key":"created_by","Value":"cloudanix"}, {"Key":"setup","Value":"'$SETUP_NUMBER'"}]' \
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

# Tag repositories if they exist (they should from the first setup)
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")

log "Verifying ECR repositories..."
for repo in "${REPOSITORIES[@]}"; do
    REPO_ARN=$(aws ecr describe-repositories --repository-names "$repo" \
        --query 'repositories[0].repositoryArn' --output text 2>/dev/null)

    if [ -n "$REPO_ARN" ] && [ "$REPO_ARN" != "None" ]; then
        log "Repository $repo exists"
    else
        log "Warning: Repository $repo not found! The script will continue but ECS services may fail."
    fi
done

# Create task definition files
log "Creating task definition files..."

cat <<EOF >  "proxyserver-task-definition-${SETUP_NUMBER}.json"
{
    "family": "proxyserver-task-${SETUP_NUMBER}",
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
                    "awslogs-group": "$LOG_GROUP_NAME_1",
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
    "memory": "4096"
}
EOF

cat <<EOF >  "proxysql-task-definition-${SETUP_NUMBER}.json"
{
    "family": "proxysql-${SETUP_NUMBER}",
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
                    "awslogs-group": "$LOG_GROUP_NAME_2",
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
    "memory": "4096"
}
EOF

cat <<EOF > "query-logging-task-definition-${SETUP_NUMBER}.json"
{
    "family": "query-logging-task-${SETUP_NUMBER}",
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
                    "awslogs-group": "$LOG_GROUP_NAME_3",
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
    "memory": "2048"
}
EOF

# Register Task Definitions
log "Registering Task Definitions..."
PROXYSERVER_TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://proxyserver-task-definition-${SETUP_NUMBER}.json --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "$PROXYSERVER_TASK_ARN" --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER

PROXYSQL_TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://proxysql-task-definition-${SETUP_NUMBER}.json --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "$PROXYSQL_TASK_ARN" --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER

QUERYLOGGING_TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://query-logging-task-definition-${SETUP_NUMBER}.json --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "$QUERYLOGGING_TASK_ARN" --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER

# Create Service Connect namespace for this setup
log "Creating Service Connect namespace..."
if ! aws servicediscovery list-namespaces --query "Namespaces[?Name=='$NAMESPACE_NAME']" --output text | grep -q 'ns-'; then
    aws servicediscovery create-private-dns-namespace \
        --name $NAMESPACE_NAME \
        --vpc $VPC_ID \
        --region $AWS_REGION
    
    wait_for_namespace "$NAMESPACE_NAME"
fi

NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --query "Namespaces[?Name=='$NAMESPACE_NAME'].Id" \
    --output text)

# Create ECS Services
log "Creating ECS Services..."
# Create ProxySQL service
aws ecs create-service \
    --cluster $ECS_CLUSTER_NAME \
    --service-name proxysql \
    --task-definition proxysql-$SETUP_NUMBER \
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'$NAMESPACE_NAME'",
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
    --task-definition proxyserver-task-$SETUP_NUMBER \
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER \
    --desired-count 2 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'$NAMESPACE_NAME'",
        "services": []
    }'

log "Creating query-logging service..."
aws ecs create-service \
    --cluster $ECS_CLUSTER_NAME \
    --service-name query-logging \
    --task-definition query-logging-task-$SETUP_NUMBER \
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix key=setup,value=$SETUP_NUMBER \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'$NAMESPACE_NAME'",
        "services": []
    }'

# Wait for services to be stable
log "Waiting for services to be stable..."
aws ecs wait services-stable \
    --cluster $ECS_CLUSTER_NAME \
    --services proxysql proxyserver

log "ECS services setup complete!"

cat << EOF > infrastructure-details-${SETUP_NUMBER}.txt
Infrastructure Details - Setup #${SETUP_NUMBER}
---------------------
VPC ID: $VPC_ID
ECS Cluster: $ECS_CLUSTER_NAME
Security Group: $ECS_SG_ID
Private Subnet 1: $PRIVATE_SUBNET_1_ID
Private Subnet 2: $PRIVATE_SUBNET_2_ID
Public Subnet 1: $PUBLIC_SUBNET_1_ID
Public Subnet 2: $PUBLIC_SUBNET_2_ID
EFS ID: $EFS_ID
Namespace: $NAMESPACE_NAME
EOF

log "Setup #${SETUP_NUMBER} deployment is complete."
log "Details saved to infrastructure-details-${SETUP_NUMBER}.txt"
