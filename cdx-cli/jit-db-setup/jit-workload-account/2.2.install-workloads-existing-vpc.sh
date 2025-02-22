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

echo "=== JIT Account Infrastructure Setup ==="
echo "Please provide the following configuration details:"
# AWS Configuration
AWS_REGION=$(prompt_with_default "AWS Region" "ap-south-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $ACCOUNT_ID"
# Project Configuration
PROJECT_NAME=$(prompt_with_default "Project Name" "cdx-jit-db")
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


echo -e "\n=== Configuration Summary ==="
echo "AWS Region: $AWS_REGION"
echo "Project Name: $PROJECT_NAME"
echo "ECS Cluster Name: $ECS_CLUSTER_NAME"
echo "Secrets Name: $SECRET_NAME"

# Create ECS Service Linked Role if it doesn't exist
log "Creating ECS Service Linked Role..."
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com || true

log "Creating ECS Task Role and policies..."

# Create the ECS task role
aws iam create-role \
    --role-name cdx-ECSTaskRole \
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

#Edit
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

# Store policy ARNs in variables
SECRETS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-ECSSecretsAccessPolicy`].Arn' --output text)
RDS_ASSUME_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-ECSRDSAssumeRolePolicy`].Arn' --output text)
EFS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`cdx-EFSAccessPolicy`].Arn' --output text)

# Attach AWS managed policies
aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"

aws iam attach-role-policy \
    --role-name cdx-ECSTaskRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

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

log "ECS Task Role and policies created successfully"

log "Creating CloudWatch Log Group..."
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_1
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_2
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_3

aws logs tag-log-group \
    --log-group-name $LOG_GROUP_NAME_1 \
    --tags '{"Purpose": "database-iam-jit", "created_by": "cloudanix"}'

aws logs tag-log-group \
    --log-group-name $LOG_GROUP_NAME_2 \
    --tags '{"Purpose": "database-iam-jit", "created_by": "cloudanix"}'

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

# Create S3 Bucket 
echo "Creating S3 Bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION
aws s3api put-bucket-tagging \
    --bucket $BUCKET_NAME \
    --tagging '{"TagSet": [{"Key": "Purpose", "Value": "database-iam-jit"}, {"Key": "created_by", "Value": "cloudanix"}]}'

# Create ECS Cluster
log "Creating ECS Cluster..."
aws ecs create-cluster \
    --cluster-name $ECS_CLUSTER_NAME \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix

# Create Security Group
log "Creating Security Group..."
ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-ecs-sg" \
    --description "Security group for ECS cluster" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value='${PROJECT_NAME}'-ecs-sg},{Key=Purpose,Value=database-iam-jit},{Key=created_by,Value=cloudanix}]' \
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
    --tags '[{"Key":"Name","Value":"'${PROJECT_NAME}'-efs"}, {"Key":"Purpose","Value":"database-iam-jit"}, {"Key":"created_by","Value":"cloudanix"}]' \
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
        aws ecr tag-resource --resource-arn "$REPO_ARN" \
            --tags "Key=Name,Value=${repo}" "Key=purpose,Value=database-iam-jit" "Key=created_by,Value=cloudanix"|| \
            log "Warning: Failed to tag ECR repository $repo"
        log "Tagged ECR repository: $repo"
    else
        log "Warning: Repository $repo not found!"
    fi
done

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
    "memory": "4096"
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
    "memory": "4096"
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
                    "value": "INFO"
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
    "memory": "2048"
}
EOF

# Register Task Definitions
log "Registering Task Definitions..."
TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://proxyserver-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "$TASK_ARN" --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix

TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://proxysql-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "$TASK_ARN" --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix

TASK_ARN=$(aws ecs register-task-definition --cli-input-json file://query-logging-task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs tag-resource --resource-arn "$TASK_ARN" --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix


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

# Create ECS Services
log "Creating ECS Services..."
# Create ProxySQL service
aws ecs create-service \
    --cluster $ECS_CLUSTER_NAME \
    --service-name proxysql \
    --task-definition proxysql \
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix \
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
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix \
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
    --tags key=Purpose,value=database-iam-jit key=created_by,value=cloudanix \
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