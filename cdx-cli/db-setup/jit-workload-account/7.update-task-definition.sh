#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# Set static variables
AWS_REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
OLD_BUCKET="jit-db-20250121011739"
NEW_BUCKET=$(prompt_with_default "Enter S3 Bucket Name" "cdx-jit-db-logs-mv-innovation" )
SECRET_NAME="CDX_SECRETS"
CDX_DC=$(prompt_with_default "CDX_DC" "IN")
CDX_API_BASE=$(prompt_with_default "CDX_API_BASE" "https://console-in.cloudanix.com")

# Get EFS ID and Access Point ID
log "Getting EFS details..."
EFS_ID=$(aws efs describe-file-systems --query 'FileSystems[?Tags[?Key==`Name` && Value==`jit-db-efs`]].FileSystemId' --output text)
if [ -z "$EFS_ID" ]; then
    log "Error: EFS filesystem not found"
    exit 1
fi

ACCESS_POINT_ID=$(aws efs describe-access-points --file-system-id $EFS_ID --query 'AccessPoints[0].AccessPointId' --output text)
if [ -z "$ACCESS_POINT_ID" ]; then
    log "Error: EFS Access Point not found"
    exit 1
fi

# Delete old S3 bucket
log "Deleting old S3 bucket: $OLD_BUCKET"
aws s3 rb s3://$OLD_BUCKET --force

# Create new S3 bucket
log "Creating new S3 bucket: $NEW_BUCKET"
aws s3api create-bucket \
    --bucket $NEW_BUCKET \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION

log "Tagging S3 bucket: $NEW_BUCKET"
aws s3api put-bucket-tagging \
    --bucket "$NEW_BUCKET" \
    --tagging "TagSet=[{Key=Name,Value=${NEW_BUCKET}},{Key=purpose,Value=database-iam-jit},{Key=created_by,Value=cloudanix}]"

log "Attaching AmazonS3FullAccess policy to ECSTaskRole..."
aws iam attach-role-policy \
    --role-name ECSTaskRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Get existing secret values
log "Getting existing secret values..."
EXISTING_SECRETS=$(aws secretsmanager get-secret-value \
    --secret-id $SECRET_NAME \
    --query 'SecretString' \
    --output text)

# Parse existing secrets and add new ones
EXISTING_JSON=$(echo $EXISTING_SECRETS | jq .)
NEW_SECRETS=$(echo $EXISTING_JSON | jq \
    --arg dc "$CDX_DC" \
    --arg api "$CDX_API_BASE" \
    --arg bucket "$NEW_BUCKET" \
    '. + {
        "CDX_DC": $dc,
        "CDX_API_BASE": $api,
        "CDX_LOGGING_S3_BUCKET": $bucket
    }')

# Update secrets in Secrets Manager
log "Updating secrets in Secrets Manager..."
aws secretsmanager update-secret \
    --secret-id $SECRET_NAME \
    --secret-string "$NEW_SECRETS"

# Create updated task definition
log "Creating updated task definition..."
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
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$SECRET_NAME:CDX_AUTH_TOKEN::"
                },
                {
                    "name": "CDX_SIGNATURE_SECRET_KEY",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$SECRET_NAME:CDX_SIGNATURE_SECRET_KEY::"
                },
                {
                    "name": "CDX_SENTRY_DSN",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$SECRET_NAME:CDX_SENTRY_DSN::"
                },
                {
                    "name": "CDX_DC",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$SECRET_NAME:CDX_DC::"
                },
                {
                    "name": "CDX_API_BASE",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$SECRET_NAME:CDX_API_BASE::"
                },
                {
                    "name": "CDX_LOGGING_S3_BUCKET",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$SECRET_NAME:CDX_LOGGING_S3_BUCKET::"
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
                    "awslogs-group": "/ecs/jit-db/proxyserver",
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

# Register new task definition
log "Registering new task definition..."
aws ecs register-task-definition --cli-input-json file://proxyserver-task-definition.json

# Update ECS service to use new task definition
log "Updating ECS service..."
aws ecs update-service \
    --cluster jit-db-cluster \
    --service proxyserver \
    --task-definition proxyserver-task \
    --force-new-deployment

log "Infrastructure update complete!"
