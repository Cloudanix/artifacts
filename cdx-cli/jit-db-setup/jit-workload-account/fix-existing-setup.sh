#!/bin/bash
set -e
set -u

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[✓] $*"; }
err() { echo "[✗] $*"; exit 1; }

# ============================================================================
# CONFIGURATION
# ============================================================================

echo "=== JIT DB Fix Script ==="
echo "This will update task definitions and redeploy services."
echo ""

SOURCE_ACCOUNT_ID="774118602354"
SOURCE_REGION="us-east-2"
IMAGE_TAG="v0.3.24"
PLATFORM="linux/amd64"

TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $TARGET_ACCOUNT_ID"

TARGET_REGION=$(prompt_with_default "Target AWS Region" "us-east-1")
ECS_CLUSTER_NAME=$(prompt_with_default "ECS Cluster Name" "cdx-jit-db-cluster")
SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name" "CDX_SECRETS")
NAMESPACE_NAME=$(prompt_with_default "Service Connect Namespace" "proxysql-proxyserver")

# Get EFS and Access Point from existing cluster
log "Fetching existing infrastructure details..."

# Get task definition to extract EFS details from any existing task
EXISTING_TD=$(aws ecs describe-task-definition --task-definition proxysql \
    --region "$TARGET_REGION" --query 'taskDefinition' 2>/dev/null || \
    aws ecs describe-task-definition --task-definition proxysql-task \
    --region "$TARGET_REGION" --query 'taskDefinition' 2>/dev/null || true)

if [ -z "$EXISTING_TD" ] || [ "$EXISTING_TD" = "" ]; then
    EFS_ID=$(prompt_with_default "EFS File System ID" "fs-xxxxxxxx")
    ACCESS_POINT_ID=$(prompt_with_default "EFS Access Point ID" "fsap-xxxxxxxx")
else
    EFS_ID=$(echo "$EXISTING_TD" | jq -r '.volumes[0].efsVolumeConfiguration.fileSystemId // empty')
    ACCESS_POINT_ID=$(echo "$EXISTING_TD" | jq -r '.volumes[0].efsVolumeConfiguration.authorizationConfig.accessPointId // empty')
    if [ -z "$EFS_ID" ] || [ -z "$ACCESS_POINT_ID" ]; then
        EFS_ID=$(prompt_with_default "EFS File System ID" "fs-xxxxxxxx")
        ACCESS_POINT_ID=$(prompt_with_default "EFS Access Point ID" "fsap-xxxxxxxx")
    else
        ok "Found EFS: $EFS_ID, Access Point: $ACCESS_POINT_ID"
    fi
fi

# Get Secret ARN
SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
    --region "$TARGET_REGION" --query 'ARN' --output text)
ok "Secret ARN: $SECRET_ARN"

# Get Security Group and Subnets from existing service
log "Fetching network config from existing services..."
NETWORK_CONFIG=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services proxysql --region "$TARGET_REGION" \
    --query 'services[0].deployments[0].networkConfiguration.awsvpcConfiguration')

SUBNETS=$(echo "$NETWORK_CONFIG" | jq -r '.subnets | join(",")')
SECURITY_GROUPS=$(echo "$NETWORK_CONFIG" | jq -r '.securityGroups | join(",")')
ok "Subnets: $SUBNETS"
ok "Security Groups: $SECURITY_GROUPS"

ECR_PREFIX="${TARGET_ACCOUNT_ID}.dkr.ecr.${TARGET_REGION}.amazonaws.com"

echo ""
echo "=== Configuration Summary ==="
echo "  Source ECR:    ${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com"
echo "  Target ECR:    ${ECR_PREFIX}"
echo "  Image Tag:     ${IMAGE_TAG}"
echo "  Cluster:       ${ECS_CLUSTER_NAME}"
echo "  Namespace:     ${NAMESPACE_NAME}"
echo "  EFS:           ${EFS_ID}"
echo "  Access Point:  ${ACCESS_POINT_ID}"
echo ""
read -p "Continue? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

echo ""
log "=== Pre-flight checks ==="

# Check secrets exist in Secrets Manager
log "Verifying secrets contain required keys..."
SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
    --region "$TARGET_REGION" --query 'SecretString' --output text)

REQUIRED_KEYS=("CDX_AUTH_TOKEN" "CDX_SIGNATURE_SECRET_KEY" "CDX_SENTRY_DSN" "CDX_DC" "CDX_API_BASE" "CDX_LOGGING_S3_BUCKET" "POSTGRES_PASSWORD" "ENCRYPTION_KEY")
MISSING_KEYS=()
for KEY in "${REQUIRED_KEYS[@]}"; do
    if ! echo "$SECRET_VALUE" | jq -e --arg k "$KEY" '.[$k] // empty' > /dev/null 2>&1; then
        MISSING_KEYS+=("$KEY")
    fi
done

if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
    err "Secret '$SECRET_NAME' is missing keys: ${MISSING_KEYS[*]}. Add them before running this script."
fi
ok "All required secret keys present"

# Ensure CloudWatch log groups exist
LOG_GROUPS=(
    "/ecs/cdx-jit-db/proxysql"
    "/ecs/cdx-jit-db/proxyserver"
    "/ecs/cdx-jit-db/query-logging"
    "/ecs/cdx-jit-db/dam-server"
    "/ecs/cdx-jit-db/postgresql"
)
for LG in "${LOG_GROUPS[@]}"; do
    aws logs create-log-group --log-group-name "$LG" --region "$TARGET_REGION" 2>/dev/null || true
done
ok "Log groups verified/created"

# Verify namespace exists
NS_ID=$(aws servicediscovery list-namespaces --region "$TARGET_REGION" \
    --query "Namespaces[?Name=='$NAMESPACE_NAME'].Id | [0]" --output text)
if [ -z "$NS_ID" ] || [ "$NS_ID" = "None" ]; then
    err "Service Connect namespace '$NAMESPACE_NAME' not found. Create it first."
fi
ok "Namespace exists: $NAMESPACE_NAME ($NS_ID)"

# Verify ECS cluster is active
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" \
    --region "$TARGET_REGION" --query 'clusters[0].status' --output text 2>/dev/null)
if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
    err "ECS cluster '$ECS_CLUSTER_NAME' is not active (status: $CLUSTER_STATUS)"
fi
ok "Cluster is active: $ECS_CLUSTER_NAME"

# Verify IAM role exists
aws iam get-role --role-name cdx-ECSTaskRole > /dev/null 2>&1 || \
    err "IAM role 'cdx-ECSTaskRole' not found."
ok "IAM role exists: cdx-ECSTaskRole"

echo ""
ok "All pre-flight checks passed!"

# ============================================================================
# STEP 1: SYNC IMAGES FROM PROD ECR
# ============================================================================

echo ""
log "=== Step 1: Syncing images from prod ECR ==="

log "Authenticating to source ECR..."
aws ecr get-login-password --region "$SOURCE_REGION" | \
    docker login --username AWS --password-stdin "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com"

log "Authenticating to target ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | \
    docker login --username AWS --password-stdin "${ECR_PREFIX}"

REPOSITORIES=(
    "cloudanix/ecr-aws-jit-proxy-sql"
    "cloudanix/ecr-aws-jit-proxy-server"
    "cloudanix/ecr-aws-jit-query-logging"
    "cloudanix/ecr-aws-jit-dam-server"
    "cloudanix/ecr-aws-jit-postgresql"
)

for REPO in "${REPOSITORIES[@]}"; do
    log "Processing: $REPO"

    # Create repo if not exists
    aws ecr describe-repositories --region "$TARGET_REGION" --repository-names "$REPO" >/dev/null 2>&1 \
        || aws ecr create-repository --region "$TARGET_REGION" --repository-name "$REPO" > /dev/null

    # Pull from source
    docker pull --platform "$PLATFORM" \
        "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}"

    # Tag for target
    docker tag \
        "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}" \
        "${ECR_PREFIX}/${REPO}:${IMAGE_TAG}"

    docker tag \
        "${SOURCE_ACCOUNT_ID}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${REPO}:${IMAGE_TAG}" \
        "${ECR_PREFIX}/${REPO}:latest"

    # Push to target
    docker push "${ECR_PREFIX}/${REPO}:${IMAGE_TAG}"
    docker push "${ECR_PREFIX}/${REPO}:latest"

    ok "Synced: $REPO:$IMAGE_TAG"
done

ok "All images synced."

# ============================================================================
# STEP 2: REGISTER CORRECTED TASK DEFINITIONS
# ============================================================================

echo ""
log "=== Step 2: Registering corrected task definitions ==="

# --- ProxySQL ---
cat > /tmp/td-proxysql.json << EOF
{
    "family": "proxysql",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "taskRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "volumes": [{
        "name": "proxysql-data",
        "efsVolumeConfiguration": {
            "fileSystemId": "${EFS_ID}",
            "rootDirectory": "/",
            "transitEncryption": "ENABLED",
            "transitEncryptionPort": 2049,
            "authorizationConfig": {
                "accessPointId": "${ACCESS_POINT_ID}",
                "iam": "ENABLED"
            }
        }
    }],
    "containerDefinitions": [{
        "name": "proxysql",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-proxy-sql:${IMAGE_TAG}",
        "cpu": 0,
        "essential": true,
        "portMappings": [
            {"containerPort": 6032, "hostPort": 6032, "protocol": "tcp", "name": "proxysql-admin"},
            {"containerPort": 6033, "hostPort": 6033, "protocol": "tcp", "name": "proxysql-mysql"}
        ],
        "environment": [],
        "mountPoints": [{"sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false}],
        "volumesFrom": [],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/cdx-jit-db/proxysql",
                "awslogs-region": "${TARGET_REGION}",
                "awslogs-stream-prefix": "ecs"
            }
        },
        "systemControls": []
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxysql.json \
    --region "$TARGET_REGION" > /dev/null
PROXYSQL_TD_ARN=$(aws ecs describe-task-definition --task-definition proxysql \
    --region "$TARGET_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Registered: proxysql ($PROXYSQL_TD_ARN)"

# --- ProxyServer ---
cat > /tmp/td-proxyserver.json << EOF
{
    "family": "proxyserver-task",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "taskRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "volumes": [{
        "name": "proxysql-data",
        "efsVolumeConfiguration": {
            "fileSystemId": "${EFS_ID}",
            "rootDirectory": "/",
            "transitEncryption": "ENABLED",
            "transitEncryptionPort": 2049,
            "authorizationConfig": {
                "accessPointId": "${ACCESS_POINT_ID}",
                "iam": "ENABLED"
            }
        }
    }],
    "containerDefinitions": [{
        "name": "proxyserver",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-proxy-server:${IMAGE_TAG}",
        "cpu": 0,
        "essential": true,
        "portMappings": [
            {"containerPort": 8079, "hostPort": 8079, "protocol": "tcp", "name": "proxyserver-http", "appProtocol": "http"}
        ],
        "environment": [
            {"name": "AWS_DEFAULT_REGION", "value": "${TARGET_REGION}"},
            {"name": "PROXYSQL_HOST", "value": "proxysql"}
        ],
        "secrets": [
            {"name": "CDX_AUTH_TOKEN", "valueFrom": "${SECRET_ARN}:CDX_AUTH_TOKEN::"},
            {"name": "CDX_SIGNATURE_SECRET_KEY", "valueFrom": "${SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name": "CDX_SENTRY_DSN", "valueFrom": "${SECRET_ARN}:CDX_SENTRY_DSN::"},
            {"name": "CDX_DC", "valueFrom": "${SECRET_ARN}:CDX_DC::"},
            {"name": "CDX_API_BASE", "valueFrom": "${SECRET_ARN}:CDX_API_BASE::"},
            {"name": "CDX_LOGGING_S3_BUCKET", "valueFrom": "${SECRET_ARN}:CDX_LOGGING_S3_BUCKET::"},
            {"name": "POSTGRES_PASSWORD", "valueFrom": "${SECRET_ARN}:POSTGRES_PASSWORD::"},
            {"name": "ENCRYPTION_KEY", "valueFrom": "${SECRET_ARN}:ENCRYPTION_KEY::"}
        ],
        "mountPoints": [{"sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false}],
        "volumesFrom": [],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/cdx-jit-db/proxyserver",
                "awslogs-region": "${TARGET_REGION}",
                "awslogs-stream-prefix": "ecs"
            }
        },
        "systemControls": []
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxyserver.json \
    --region "$TARGET_REGION" > /dev/null
PROXYSERVER_TD_ARN=$(aws ecs describe-task-definition --task-definition proxyserver-task \
    --region "$TARGET_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Registered: proxyserver-task ($PROXYSERVER_TD_ARN)"

# --- Query Logging ---
cat > /tmp/td-query-logging.json << EOF
{
    "family": "query-logging-task",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "taskRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "volumes": [{
        "name": "proxysql-data",
        "efsVolumeConfiguration": {
            "fileSystemId": "${EFS_ID}",
            "rootDirectory": "/",
            "transitEncryption": "ENABLED",
            "transitEncryptionPort": 2049,
            "authorizationConfig": {
                "accessPointId": "${ACCESS_POINT_ID}",
                "iam": "ENABLED"
            }
        }
    }],
    "containerDefinitions": [{
        "name": "query-logging",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-query-logging:${IMAGE_TAG}",
        "cpu": 0,
        "essential": true,
        "portMappings": [
            {"containerPort": 8079, "hostPort": 8079, "protocol": "tcp", "name": "query-logging-port", "appProtocol": "http"}
        ],
        "environment": [
            {"name": "AWS_DEFAULT_REGION", "value": "${TARGET_REGION}"},
            {"name": "CDX_APP_ENV", "value": "production"},
            {"name": "CDX_LOG_LEVEL", "value": "DEBUG"},
            {"name": "CDX_DEFAULT_REGION", "value": "${TARGET_REGION}"},
            {"name": "CDX_SERVER_VERSION", "value": "1.0.0"}
        ],
        "secrets": [
            {"name": "CDX_AUTH_TOKEN", "valueFrom": "${SECRET_ARN}:CDX_AUTH_TOKEN::"},
            {"name": "CDX_SIGNATURE_SECRET_KEY", "valueFrom": "${SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name": "CDX_SENTRY_DSN", "valueFrom": "${SECRET_ARN}:CDX_SENTRY_DSN::"},
            {"name": "CDX_DC", "valueFrom": "${SECRET_ARN}:CDX_DC::"},
            {"name": "CDX_API_BASE", "valueFrom": "${SECRET_ARN}:CDX_API_BASE::"},
            {"name": "CDX_LOGGING_S3_BUCKET", "valueFrom": "${SECRET_ARN}:CDX_LOGGING_S3_BUCKET::"},
            {"name": "POSTGRES_PASSWORD", "valueFrom": "${SECRET_ARN}:POSTGRES_PASSWORD::"},
            {"name": "ENCRYPTION_KEY", "valueFrom": "${SECRET_ARN}:ENCRYPTION_KEY::"}
        ],
        "mountPoints": [{"sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false}],
        "volumesFrom": [],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/cdx-jit-db/query-logging",
                "awslogs-region": "${TARGET_REGION}",
                "awslogs-stream-prefix": "ecs"
            }
        },
        "systemControls": []
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-query-logging.json \
    --region "$TARGET_REGION" > /dev/null
QUERYLOGGING_TD_ARN=$(aws ecs describe-task-definition --task-definition query-logging-task \
    --region "$TARGET_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Registered: query-logging-task ($QUERYLOGGING_TD_ARN)"

# --- DAM Server ---
cat > /tmp/td-dam-server.json << EOF
{
    "family": "dam-server-task",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "taskRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "volumes": [{
        "name": "proxysql-data",
        "efsVolumeConfiguration": {
            "fileSystemId": "${EFS_ID}",
            "rootDirectory": "/",
            "transitEncryption": "ENABLED",
            "transitEncryptionPort": 2049,
            "authorizationConfig": {
                "accessPointId": "${ACCESS_POINT_ID}",
                "iam": "ENABLED"
            }
        }
    }],
    "containerDefinitions": [{
        "name": "dam-server",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-dam-server:${IMAGE_TAG}",
        "cpu": 0,
        "essential": true,
        "portMappings": [
            {"containerPort": 8080, "hostPort": 8080, "protocol": "tcp", "name": "dam-server-http"}
        ],
        "environment": [
            {"name": "AWS_DEFAULT_REGION", "value": "${TARGET_REGION}"},
            {"name": "NODE_ENV", "value": "production"},
            {"name": "PROXYSERVER_HOST", "value": "proxyserver"},
            {"name": "PROXYSERVER_PORT", "value": "8079"},
            {"name": "DAM_LOG_LEVEL", "value": "INFO"},
            {"name": "DAM_APP_ENV", "value": "production"}
        ],
        "secrets": [
            {"name": "CDX_AUTH_TOKEN", "valueFrom": "${SECRET_ARN}:CDX_AUTH_TOKEN::"},
            {"name": "CDX_SIGNATURE_SECRET_KEY", "valueFrom": "${SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name": "CDX_SENTRY_DSN", "valueFrom": "${SECRET_ARN}:CDX_SENTRY_DSN::"},
            {"name": "CDX_DC", "valueFrom": "${SECRET_ARN}:CDX_DC::"},
            {"name": "CDX_API_BASE", "valueFrom": "${SECRET_ARN}:CDX_API_BASE::"},
            {"name": "POSTGRES_PASSWORD", "valueFrom": "${SECRET_ARN}:POSTGRES_PASSWORD::"}
        ],
        "mountPoints": [{"sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false}],
        "volumesFrom": [],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/cdx-jit-db/dam-server",
                "awslogs-region": "${TARGET_REGION}",
                "awslogs-stream-prefix": "ecs"
            }
        },
        "systemControls": []
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-dam-server.json \
    --region "$TARGET_REGION" > /dev/null
DAMSERVER_TD_ARN=$(aws ecs describe-task-definition --task-definition dam-server-task \
    --region "$TARGET_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Registered: dam-server-task ($DAMSERVER_TD_ARN)"

# --- PostgreSQL ---
cat > /tmp/td-postgresql.json << EOF
{
    "family": "postgresql-task",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "taskRoleArn": "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/cdx-ECSTaskRole",
    "volumes": [{
        "name": "proxysql-data",
        "efsVolumeConfiguration": {
            "fileSystemId": "${EFS_ID}",
            "rootDirectory": "/",
            "transitEncryption": "ENABLED",
            "transitEncryptionPort": 2049,
            "authorizationConfig": {
                "accessPointId": "${ACCESS_POINT_ID}",
                "iam": "ENABLED"
            }
        }
    }],
    "containerDefinitions": [{
        "name": "postgresql",
        "image": "${ECR_PREFIX}/cloudanix/ecr-aws-jit-postgresql:${IMAGE_TAG}",
        "cpu": 0,
        "essential": true,
        "portMappings": [
            {"containerPort": 5432, "hostPort": 5432, "protocol": "tcp", "name": "postgresql-db"}
        ],
        "environment": [
            {"name": "POSTGRES_USER", "value": "pgjitdbuser"},
            {"name": "POSTGRES_DB", "value": "jitdb"},
            {"name": "PGDATA", "value": "/var/lib/proxysql/postgresql/data/pgdata"},
            {"name": "POSTGRES_INITDB_ARGS", "value": "-E UTF8 --locale=en_US.utf8"}
        ],
        "secrets": [
            {"name": "POSTGRES_PASSWORD", "valueFrom": "${SECRET_ARN}:POSTGRES_PASSWORD::"}
        ],
        "mountPoints": [{"sourceVolume": "proxysql-data", "containerPath": "/var/lib/proxysql", "readOnly": false}],
        "volumesFrom": [],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/cdx-jit-db/postgresql",
                "awslogs-region": "${TARGET_REGION}",
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
    }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-postgresql.json \
    --region "$TARGET_REGION" > /dev/null
POSTGRESQL_TD_ARN=$(aws ecs describe-task-definition --task-definition postgresql-task \
    --region "$TARGET_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Registered: postgresql-task ($POSTGRESQL_TD_ARN)"

ok "All 5 task definitions registered."

# ============================================================================
# STEP 3: DELETE AND RECREATE SERVICES IN CORRECT ORDER
# ============================================================================

echo ""
log "=== Step 3: Recreating services with correct Service Connect ==="

NETWORK_CFG="awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}"

# Delete all existing services (scale to 0 first for faster deletion)
ALL_SERVICES=("query-logging" "proxyserver" "dam-server" "postgresql" "proxysql")

log "Scaling down all services..."
for SVC in "${ALL_SERVICES[@]}"; do
    aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SVC" \
        --desired-count 0 --region "$TARGET_REGION" --output text > /dev/null 2>&1 || true
done

sleep 10

log "Deleting all services..."
for SVC in "${ALL_SERVICES[@]}"; do
    aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$SVC" \
        --force --region "$TARGET_REGION" --output text > /dev/null 2>&1 || true
    log "  Deleted: $SVC"
done

# Wait for services to be fully deleted
log "Waiting for services to drain..."
for SVC in "${ALL_SERVICES[@]}"; do
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 12 ]; do
        SVC_STATUS=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
            --services "$SVC" --region "$TARGET_REGION" \
            --query 'services[0].status' --output text 2>/dev/null)
        if [ "$SVC_STATUS" = "INACTIVE" ] || [ "$SVC_STATUS" = "None" ] || [ -z "$SVC_STATUS" ]; then
            break
        fi
        sleep 10
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
done
ok "All services deleted"

# Recreate in correct dependency order
# 1. ProxySQL (no dependencies)
log "Creating proxysql service..."
aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name proxysql \
    --task-definition "$PROXYSQL_TD_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "$NETWORK_CFG" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'"$NAMESPACE_NAME"'",
        "services": [{
            "portName": "proxysql-admin",
            "discoveryName": "proxysql",
            "clientAliases": [{"port": 6032, "dnsName": "proxysql"}]
        }]
    }' \
    --region "$TARGET_REGION" > /dev/null
ok "Created: proxysql"

# 2. PostgreSQL (no dependencies, but others depend on it)
log "Creating postgresql service..."
aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name postgresql \
    --task-definition "$POSTGRESQL_TD_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "$NETWORK_CFG" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'"$NAMESPACE_NAME"'",
        "services": [{
            "portName": "postgresql-db",
            "discoveryName": "postgresql",
            "clientAliases": [{"port": 5432, "dnsName": "postgresql"}]
        }]
    }' \
    --region "$TARGET_REGION" > /dev/null
ok "Created: postgresql"

# 3. ProxyServer (depends on proxysql)
log "Creating proxyserver service..."
aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name proxyserver \
    --task-definition "$PROXYSERVER_TD_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "$NETWORK_CFG" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'"$NAMESPACE_NAME"'",
        "services": [{
            "portName": "proxyserver-http",
            "discoveryName": "proxyserver",
            "clientAliases": [{"port": 8079, "dnsName": "proxyserver"}]
        }]
    }' \
    --region "$TARGET_REGION" > /dev/null
ok "Created: proxyserver"

# Wait for postgresql to be stable before creating dependent services
log "Waiting for postgresql to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" \
    --services postgresql --region "$TARGET_REGION"
ok "postgresql is stable"

# 4. DAM Server (depends on postgresql + proxyserver)
log "Creating dam-server service..."
aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name dam-server \
    --task-definition "$DAMSERVER_TD_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "$NETWORK_CFG" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'"$NAMESPACE_NAME"'",
        "services": [{
            "portName": "dam-server-http",
            "discoveryName": "dam-server",
            "clientAliases": [{"port": 8080, "dnsName": "dam-server"}]
        }]
    }' \
    --region "$TARGET_REGION" > /dev/null
ok "Created: dam-server"

# Wait for dam-server to be stable
log "Waiting for dam-server to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" \
    --services dam-server --region "$TARGET_REGION"
ok "dam-server is stable"

# 5. Query Logging (depends on postgresql)
log "Creating query-logging service..."
aws ecs create-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service-name query-logging \
    --task-definition "$QUERYLOGGING_TD_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "$NETWORK_CFG" \
    --enable-execute-command \
    --service-connect-configuration '{
        "enabled": true,
        "namespace": "'"$NAMESPACE_NAME"'",
        "services": []
    }' \
    --region "$TARGET_REGION" > /dev/null
ok "Created: query-logging"

# Wait for all services to be stable
log "Waiting for all services to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" \
    --services proxysql proxyserver query-logging dam-server postgresql \
    --region "$TARGET_REGION"

ok "All services are stable!"

# ============================================================================
# STEP 4: VERIFY
# ============================================================================

echo ""
log "=== Step 4: Verification ==="

aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services proxysql proxyserver postgresql dam-server query-logging \
    --region "$TARGET_REGION" \
    --query 'services[].{Name:serviceName,Status:status,Running:runningCount,Desired:desiredCount,TaskDef:taskDefinition}' \
    --output table

echo ""
echo "=== Fix Complete ==="
echo ""
echo "Services recreated in order:"
echo "  1. proxysql        (Client & Server - proxysql:6032)"
echo "  2. postgresql      (Client & Server - postgresql:5432)"
echo "  3. proxyserver     (Client & Server - proxyserver:8079)"
echo "  4. dam-server      (Client & Server - dam-server:8080)"
echo "  5. query-logging   (Client only)"
echo ""
echo "All task definitions updated with correct secrets."
echo "Check CloudWatch logs to confirm no DNS resolution errors."

# Cleanup temp files
rm -f /tmp/td-proxysql.json /tmp/td-proxyserver.json /tmp/td-query-logging.json \
      /tmp/td-dam-server.json /tmp/td-postgresql.json
