#!/bin/bash
set -e  
set -u  

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

#Edit
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $ACCOUNT_ID"
AWS_REGION="ap-south-1"
PROJECT_NAME="jit-db"
VPC_CIDR="10.10.0.0/16"
PRIVATE_SUBNET_1_CIDR="10.10.1.0/24"
PRIVATE_SUBNET_2_CIDR="10.10.2.0/24"
PUBLIC_SUBNET_1_CIDR="10.10.3.0/24"
PUBLIC_SUBNET_2_CIDR="10.10.4.0/24"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/cloudanix/ecr-aws-jit-proxy-server"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/cloudanix/ecr-aws-jit-proxy-sql"
SECRET_NAME="CDX_SECRETS"
CDX_AUTH_TOKEN="AUTH_TOKEN_1234567890"
CDX_SIGNATURE_SECRET_KEY="SECRET_1234567890"
CDX_SENTRY_DSN="CDX_SENTRY_DSN"


# Create ECS Service Linked Role if it doesn't exist
log "Creating ECS Service Linked Role..."
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com || true

# Create VPC
log "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
    --query 'Vpc.VpcId' \
    --output text)

# Enable DNS hostname for VPC
aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-hostnames

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

# Attach IGW to VPC
aws ec2 attach-internet-gateway \
    --vpc-id $VPC_ID \
    --internet-gateway-id $IGW_ID

# Create Subnets
log "Creating subnets..."
PRIVATE_SUBNET_1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_1_CIDR \
    --availability-zone "${AWS_REGION}a" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-1}]" \
    --query 'Subnet.SubnetId' \
    --output text)

PRIVATE_SUBNET_2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_2_CIDR \
    --availability-zone "${AWS_REGION}b" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-2}]" \
    --query 'Subnet.SubnetId' \
    --output text)

PUBLIC_SUBNET_1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_1_CIDR \
    --availability-zone "${AWS_REGION}a" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-1}]" \
    --query 'Subnet.SubnetId' \
    --output text)

PUBLIC_SUBNET_2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_2_CIDR \
    --availability-zone "${AWS_REGION}b" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-2}]" \
    --query 'Subnet.SubnetId' \
    --output text)

# Create NAT Gateway
log "Creating NAT Gateway..."
ELASTIC_IP_ID=$(aws ec2 allocate-address \
    --domain vpc \
    --query 'AllocationId' \
    --output text)

NAT_GATEWAY_ID=$(aws ec2 create-nat-gateway \
    --subnet-id $PUBLIC_SUBNET_1_ID \
    --allocation-id $ELASTIC_IP_ID \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat}]" \
    --query 'NatGateway.NatGatewayId' \
    --output text)

wait_for_nat_gateway "$NAT_GATEWAY_ID"

# Create Route Tables
log "Creating route tables..."
PUBLIC_RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)

PRIVATE_RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rt}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)

# Create Routes
aws ec2 create-route \
    --route-table-id $PUBLIC_RT_ID \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id $IGW_ID

aws ec2 create-route \
    --route-table-id $PRIVATE_RT_ID \
    --destination-cidr-block "0.0.0.0/0"\
    --nat-gateway-id $NAT_GATEWAY_ID

# Associate Route Tables
log "Associating route tables..."
aws ec2 associate-route-table \
    --subnet-id $PUBLIC_SUBNET_1_ID \
    --route-table-id $PUBLIC_RT_ID

aws ec2 associate-route-table \
    --subnet-id $PUBLIC_SUBNET_2_ID \
    --route-table-id $PUBLIC_RT_ID

aws ec2 associate-route-table \
    --subnet-id $PRIVATE_SUBNET_1_ID \
    --route-table-id $PRIVATE_RT_ID

aws ec2 associate-route-table \
    --subnet-id $PRIVATE_SUBNET_2_ID \
    --route-table-id $PRIVATE_RT_ID

log "Creating ECS Task Role and policies..."

# Create the ECS task role
aws iam create-role \
    --role-name ECSTaskRole \
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
    --policy-name ECSSecretsAccessPolicy \
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
    --policy-name ECSRDSAssumeRolePolicy \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": "sts:AssumeRole",
            "Resource": [
                "*",
            ]
        }]
    }'

# Create EFS access policy
log "Creating EFS access policy..."
aws iam create-policy \
    --policy-name EFSAccessPolicy \
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
SECRETS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`ECSSecretsAccessPolicy`].Arn' --output text)
RDS_ASSUME_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`ECSRDSAssumeRolePolicy`].Arn' --output text)
EFS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`EFSAccessPolicy`].Arn' --output text)

# Attach AWS managed policies
aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"

# Attach custom policies
aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn $SECRETS_POLICY_ARN

aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn $RDS_ASSUME_POLICY_ARN

aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn $EFS_POLICY_ARN

log "ECS Task Role and policies created successfully"

log "Creating CloudWatch Log Group..."
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_1
aws logs create-log-group --log-group-name $LOG_GROUP_NAME_2

log "Creating Secrets in Secret Manager ..."
SECRET_ARN=$(aws secretsmanager create-secret \
    --name $SECRET_NAME \
    --description "Secrets for CDX" \
    --secret-string "{\"CDX_AUTH_TOKEN\": \"$CDX_AUTH_TOKEN\", \"CDX_SIGNATURE_SECRET_KEY\": \"$CDX_SIGNATURE_SECRET_KEY\", \"CDX_SENTRY_DSN\": \"$CDX_SENTRY_DSN\"}" \
    --query 'ARN' \
    --output text)

wait_for_secret $SECRET_NAME

echo "Create S3 Bucket"
BUCKET_NAME="${PROJECT_NAME}-$(date +%Y%m%d%H%M%S)"
echo "Creating S3 Bucket: $BUCKET_NAME"
aws s3api create-bucket \
    --bucket $BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION

# Create ECS Cluster
log "Creating ECS Cluster..."
aws ecs create-cluster \
    --cluster-name $ECS_CLUSTER_NAME \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1

# Create Security Group
log "Creating Security Group..."
ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-ecs-sg" \
    --description "Security group for ECS cluster" \
    --vpc-id $VPC_ID \
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
    --tags Key=Name,Value=${PROJECT_NAME}-efs \
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
                },
                {
                    "name": "S3_BUCKET_NAME",
                    "value": "$BUCKET_NAME"
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
                }
              ],
            "mountPoints": [],
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
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ECSTaskRole",
    "networkMode": "awsvpc",
    "volumes": [],
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
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ECSTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ECSTaskRole",
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

# Register Task Definitions
log "Registering Task Definitions..."
aws ecs register-task-definition --cli-input-json file://proxyserver-task-definition.json
aws ecs register-task-definition --cli-input-json file://proxysql-task-definition.json

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