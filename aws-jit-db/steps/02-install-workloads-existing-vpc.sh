#!/usr/bin/env bash
# =============================================================================
# Step: Install Workloads (Existing VPC)
# =============================================================================
# Deploys JIT DB infrastructure into a user-provided existing VPC.
# Does NOT create VPC, subnets, NAT Gateway, IGW, or route tables.
# Creates everything else:
#   - ECS Service-Linked Role
#   - IAM Task Role with all required policies
#   - CloudWatch Log Groups (per service)
#   - Secrets Manager secret
#   - S3 bucket for query logs
#   - Security group with self-referencing rules
#   - EFS filesystem with access point and mount targets
#   - ECS Cluster (Fargate)
#   - Service Connect namespace
#   - Task definitions (proxysql, proxyserver, query-logging, dam-server, postgresql)
#   - ECS services with Service Connect
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, BUCKET_NAME, SECRET_NAME,
#   CDX_AUTH_TOKEN, CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN, CDX_DC,
#   CDX_API_BASE, ECS_CLUSTER_NAME, ENABLE_DAM, IMAGE_TAG,
#   VPC_ID, PRIVATE_SUBNET_1_ID, PRIVATE_SUBNET_2_ID
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:ECS_CLUSTER_ARN, OUTPUT:ECS_SG_ID, OUTPUT:EFS_ID,
#   OUTPUT:SECRET_ARN, OUTPUT:PRIVATE_SUBNET_1_ID, OUTPUT:PRIVATE_SUBNET_2_ID,
#   OUTPUT:NAMESPACE_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
export CDX_PURPOSE=jit_db

require_env AWS_REGION PROJECT_NAME BUCKET_NAME SECRET_NAME \
    CDX_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN CDX_DC CDX_API_BASE \
    ECS_CLUSTER_NAME ENABLE_DAM ENCRYPTION_KEY VPC_ID PRIVATE_SUBNET_1_ID PRIVATE_SUBNET_2_ID

IMAGE_TAG="${IMAGE_TAG:-latest}"

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
export AWS_DEFAULT_REGION="$AWS_REGION"

ROLE_NAME="${PROJECT_NAME}-ECSRole"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Resolve container image URIs per service, honoring the ECR sourcing mode.
IMG_PROXYSERVER=$(cdx_image_uri "proxy-server" "$IMAGE_TAG")
IMG_PROXYSQL=$(cdx_image_uri "proxy-sql" "$IMAGE_TAG")
IMG_QUERY_LOGGING=$(cdx_image_uri "query-logging" "$IMAGE_TAG")
IMG_DAM_SERVER=$(cdx_image_uri "dam-server" "$IMAGE_TAG")
IMG_POSTGRESQL=$(cdx_image_uri "postgresql" "$IMAGE_TAG")

# Log groups (per service)
LOG_GROUP_PROXYSERVER="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_PROXYSQL="/ecs/${PROJECT_NAME}/proxysql"
LOG_GROUP_QUERY_LOGGING="/ecs/${PROJECT_NAME}/query-logging"
LOG_GROUP_DAM_SERVER="/ecs/${PROJECT_NAME}/dam-server"
LOG_GROUP_POSTGRESQL="/ecs/${PROJECT_NAME}/postgresql"

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Project: $PROJECT_NAME"
info "VPC: $VPC_ID | Subnets: $PRIVATE_SUBNET_1_ID, $PRIVATE_SUBNET_2_ID"
info "Image source mode: ${CDX_ECR_MODE:-pull-through}"

# =============================================================================
# ECR PULL-THROUGH CACHE (default image sourcing)
# =============================================================================
if [[ "${CDX_ECR_MODE:-pull-through}" != "sync" ]]; then
    step "ECR Pull-Through Cache"
    cdx_ensure_pull_through_cache
fi

# =============================================================================
# ENABLE VPC DNS (required for EFS mount target DNS resolution)
# =============================================================================

step "VPC DNS Settings"
# EFS mounts resolve fs-xxx.efs.<region>.amazonaws.com — needs DNS hostnames+support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' 2>/dev/null || true
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' 2>/dev/null || true
ok "DNS hostnames + support enabled on $VPC_ID"

# =============================================================================
# ECS SERVICE-LINKED ROLE
# =============================================================================

aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

# =============================================================================
# IAM ROLE & POLICIES
# =============================================================================

step "IAM Role & Policies"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags $(cdx_tags_kv) > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "IAM Role created: $ROLE_NAME"
else
    ok "IAM Role exists: $ROLE_NAME"
fi

# Attach managed policies
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

# Secrets Manager policy
SECRETS_POLICY_NAME="${PROJECT_NAME}-SecretsAccess"
SECRETS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${SECRETS_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$SECRETS_POLICY_ARN" > /dev/null 2>&1; then
    SECRETS_POLICY_ARN=$(aws iam create-policy --policy-name "$SECRETS_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":\"arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:*\"}]}" \
        --tags $(cdx_tags_kv) \
        --query 'Policy.Arn' --output text)
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$SECRETS_POLICY_ARN"

# EFS access policy
EFS_POLICY_NAME="${PROJECT_NAME}-EFSAccess"
EFS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${EFS_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$EFS_POLICY_ARN" > /dev/null 2>&1; then
    EFS_POLICY_ARN=$(aws iam create-policy --policy-name "$EFS_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"elasticfilesystem:ClientMount\",\"elasticfilesystem:ClientWrite\",\"elasticfilesystem:DescribeMountTargets\"],\"Resource\":\"arn:aws:elasticfilesystem:${AWS_REGION}:${ACCOUNT_ID}:file-system/*\"}]}" \
        --tags $(cdx_tags_kv) \
        --query 'Policy.Arn' --output text)
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$EFS_POLICY_ARN"

# S3 access policy
S3_POLICY_NAME="${PROJECT_NAME}-S3Access"
S3_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$S3_POLICY_ARN" > /dev/null 2>&1; then
    S3_POLICY_ARN=$(aws iam create-policy --policy-name "$S3_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:*\",\"s3-object-lambda:*\"],\"Resource\":[\"arn:aws:s3:::${BUCKET_NAME}\",\"arn:aws:s3:::${BUCKET_NAME}/*\"]}]}" \
        --tags $(cdx_tags_kv) \
        --query 'Policy.Arn' --output text)
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$S3_POLICY_ARN"

# CloudWatch Logs policy
LOGS_POLICY_NAME="${PROJECT_NAME}-CloudWatchLogs"
LOGS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$LOGS_POLICY_ARN" > /dev/null 2>&1; then
    LOG_ARNS="\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/*\""
    LOGS_POLICY_ARN=$(aws iam create-policy --policy-name "$LOGS_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"logs:*\",\"cloudwatch:GenerateQuery\"],\"Resource\":[${LOG_ARNS}]}]}" \
        --tags $(cdx_tags_kv) \
        --query 'Policy.Arn' --output text)
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$LOGS_POLICY_ARN"

# ECR pull-through cache permissions (default image sourcing).
if [[ "${CDX_ECR_MODE:-pull-through}" != "sync" ]]; then
    cdx_attach_pull_through_iam "$ROLE_NAME"
fi

ok "All IAM policies attached to $ROLE_NAME"

# Wait for IAM policy propagation (AWS eventual consistency)
info "Waiting for IAM policies to propagate..."
sleep 10

ATTACHED_COUNT=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'length(AttachedPolicies)' --output text)
if [[ "$ATTACHED_COUNT" -lt 4 ]]; then
    error "Expected at least 4 policies attached to $ROLE_NAME, found $ATTACHED_COUNT"
    exit 1
fi
ok "Verified: $ATTACHED_COUNT policies attached"

# =============================================================================
# CLOUDWATCH LOG GROUPS
# =============================================================================

step "CloudWatch Log Groups"
aws logs create-log-group --log-group-name "$LOG_GROUP_PROXYSERVER" 2>/dev/null || true
aws logs create-log-group --log-group-name "$LOG_GROUP_PROXYSQL" 2>/dev/null || true
aws logs create-log-group --log-group-name "$LOG_GROUP_QUERY_LOGGING" 2>/dev/null || true

if [[ "$ENABLE_DAM" == "true" ]]; then
    aws logs create-log-group --log-group-name "$LOG_GROUP_DAM_SERVER" 2>/dev/null || true
    aws logs create-log-group --log-group-name "$LOG_GROUP_POSTGRESQL" 2>/dev/null || true
fi
ok "Log groups created"

# =============================================================================
# SECRETS MANAGER
# =============================================================================

step "Secrets Manager"
SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
    --query 'ARN' --output text 2>/dev/null) || SECRET_ARN=""
if [[ -z "$SECRET_ARN" || "$SECRET_ARN" == "None" ]]; then
    # Build secret JSON
    SECRET_JSON=$(jq -n \
        --arg token "$CDX_AUTH_TOKEN" \
        --arg sig "$CDX_SIGNATURE_SECRET_KEY" \
        --arg sentry "$CDX_SENTRY_DSN" \
        --arg dc "$CDX_DC" \
        --arg api "$CDX_API_BASE" \
        --arg bucket "$BUCKET_NAME" \
        '{CDX_AUTH_TOKEN:$token, CDX_SIGNATURE_SECRET_KEY:$sig, CDX_SENTRY_DSN:$sentry, CDX_DC:$dc, CDX_API_BASE:$api, CDX_LOGGING_S3_BUCKET:$bucket}')

    if [[ "$ENABLE_DAM" == "true" ]]; then
        POSTGRES_PASSWORD=$(openssl rand -base64 32)
        SECRET_JSON=$(echo "$SECRET_JSON" | jq \
            --arg pg_pass "$POSTGRES_PASSWORD" \
            --arg enc_key "$ENCRYPTION_KEY" \
            '. + {POSTGRES_PASSWORD:$pg_pass, ENCRYPTION_KEY:$enc_key}')
    fi

    SECRET_ARN=$(aws secretsmanager create-secret --name "$SECRET_NAME" \
        --description "Secrets for CDX JIT DB" \
        --secret-string "$SECRET_JSON" \
        --tags $(cdx_tags_kv) \
        --query 'ARN' --output text)
    ok "Secret created: $SECRET_NAME"
else
    ok "Secret exists: $SECRET_NAME"
fi

# =============================================================================
# S3 BUCKET
# =============================================================================

step "S3 Bucket"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
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
# SECURITY GROUP
# =============================================================================

step "Security Group"
ECS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$ECS_SG" || "$ECS_SG" == "None" ]]; then
    ECS_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ecs-sg" \
        --description "Security group for ECS cluster" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-ecs-sg},")]" \
        --query 'GroupId' --output text)
    # Internal communication rules
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 6032 --source-group "$ECS_SG" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 6033 --source-group "$ECS_SG" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8079 --source-group "$ECS_SG" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG" > /dev/null
    aws ec2 authorize-security-group-egress --group-id "$ECS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG" > /dev/null 2>&1 || true

    if [[ "$ENABLE_DAM" == "true" ]]; then
        aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 5432 --source-group "$ECS_SG" > /dev/null
        aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8080 --source-group "$ECS_SG" > /dev/null
        aws ec2 authorize-security-group-egress --group-id "$ECS_SG" --protocol tcp --port 5432 --source-group "$ECS_SG" > /dev/null 2>&1 || true
    fi
    ok "ECS SG created: $ECS_SG"
else
    ok "ECS SG exists: $ECS_SG"
fi

# =============================================================================
# EFS FILESYSTEM & ACCESS POINT
# =============================================================================

step "EFS"
EFS_ID=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" \
    --output text 2>/dev/null)
if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
    EFS_ID=$(aws efs create-file-system --performance-mode generalPurpose \
        --throughput-mode bursting --encrypted \
        --tags "Key=Name,Value=${PROJECT_NAME}-efs" $(cdx_tags_kv) \
        --query 'FileSystemId' --output text)
    info "Waiting for EFS..."
    while true; do
        STATUS=$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
            --query 'FileSystems[0].LifeCycleState' --output text)
        [[ "$STATUS" == "available" ]] && break
        sleep 5
    done
    ok "EFS created: $EFS_ID"
else
    ok "EFS exists: $EFS_ID"
fi

# Mount targets in private subnets
for SUB in "$PRIVATE_SUBNET_1_ID" "$PRIVATE_SUBNET_2_ID"; do
    EXISTING_MT=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query "MountTargets[?SubnetId=='${SUB}'].MountTargetId | [0]" --output text 2>/dev/null)
    if [[ -z "$EXISTING_MT" || "$EXISTING_MT" == "None" ]]; then
        aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUB" \
            --security-groups "$ECS_SG" > /dev/null
    fi
done

# CRITICAL: wait until ALL mount targets are 'available' before launching ECS
# tasks that mount EFS (otherwise the task fails to resolve the mount target).
info "Waiting for EFS mount targets to become available..."
for _i in $(seq 1 40); do
    NOT_READY=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query "length(MountTargets[?LifeCycleState!='available'])" --output text 2>/dev/null)
    [[ "$NOT_READY" == "0" ]] && break
    sleep 5
done
ok "EFS mount targets available"

# Access point
ACCESS_POINT_ID=$(aws efs describe-access-points \
    --query "AccessPoints[?FileSystemId=='${EFS_ID}' && RootDirectory.Path=='/proxysql-data'].AccessPointId | [0]" \
    --output text 2>/dev/null)
if [[ -z "$ACCESS_POINT_ID" || "$ACCESS_POINT_ID" == "None" ]]; then
    ACCESS_POINT_ID=$(aws efs create-access-point --file-system-id "$EFS_ID" \
        --posix-user "Uid=1000,Gid=1000" \
        --root-directory "Path=/proxysql-data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=777}" \
        --tags $(cdx_tags_kv) \
        --query 'AccessPointId' --output text)
    ok "EFS Access Point created: $ACCESS_POINT_ID"
else
    ok "EFS Access Point exists: $ACCESS_POINT_ID"
fi

# =============================================================================
# ECS CLUSTER
# =============================================================================

step "ECS Cluster"
CLUSTER_ARN=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" \
    --query 'clusters[?status==`ACTIVE`].clusterArn | [0]' --output text 2>/dev/null)
if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
    CLUSTER_ARN=$(aws ecs create-cluster --cluster-name "$ECS_CLUSTER_NAME" \
        --capacity-providers FARGATE FARGATE_SPOT \
        --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
        --tags $(cdx_tags_ecs) \
        --query 'cluster.clusterArn' --output text)
    ok "Cluster created: $ECS_CLUSTER_NAME"
else
    ok "Cluster exists: $ECS_CLUSTER_NAME"
fi

# =============================================================================
# SERVICE CONNECT NAMESPACE
# =============================================================================

step "Service Connect Namespace"
NAMESPACE_NAME="proxysql-proxyserver"
NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null)
if [[ -z "$NAMESPACE_ID" || "$NAMESPACE_ID" == "None" ]]; then
    aws servicediscovery create-private-dns-namespace \
        --name "$NAMESPACE_NAME" --vpc "$VPC_ID" --region "$AWS_REGION" > /dev/null
    # Wait for namespace
    for _i in $(seq 1 10); do
        NAMESPACE_ID=$(aws servicediscovery list-namespaces \
            --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null)
        [[ -n "$NAMESPACE_ID" && "$NAMESPACE_ID" != "None" ]] && break
        sleep 10
    done
    ok "Namespace created: $NAMESPACE_NAME ($NAMESPACE_ID)"
else
    ok "Namespace exists: $NAMESPACE_NAME ($NAMESPACE_ID)"
fi

# =============================================================================
# TASK DEFINITIONS
# =============================================================================

step "Task Definitions"

# Common volume config for EFS
VOLUME_CONFIG=$(jq -n \
    --arg fsid "$EFS_ID" \
    --arg apid "$ACCESS_POINT_ID" \
    '[{"name":"proxysql-data","efsVolumeConfiguration":{"fileSystemId":$fsid,"rootDirectory":"/","transitEncryption":"ENABLED","transitEncryptionPort":2049,"authorizationConfig":{"accessPointId":$apid,"iam":"ENABLED"}}}]')

# ---- ProxyServer Task Definition ----
PROXYSERVER_TD=$(jq -n \
    --arg family "proxyserver-task" \
    --arg image "$IMG_PROXYSERVER" \
    --arg role "$ROLE_ARN" \
    --arg region "$AWS_REGION" \
    --arg lg "$LOG_GROUP_PROXYSERVER" \
    --arg secret_arn "$SECRET_ARN" \
    --argjson volumes "$VOLUME_CONFIG" \
    '{
        family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
        cpu: "256", memory: "1024", executionRoleArn: $role, taskRoleArn: $role,
        volumes: $volumes,
        containerDefinitions: [{
            name: "proxyserver",
            image: $image,
            cpu: 0, essential: true,
            portMappings: [{name:"proxyserver-http", containerPort:8079, hostPort:8079, protocol:"tcp"}],
            environment: [
                {name:"AWS_DEFAULT_REGION", value:$region},
                {name:"PROXYSQL_HOST", value:"proxysql"}
            ],
            secrets: [
                {name:"CDX_AUTH_TOKEN", valueFrom:"\($secret_arn):CDX_AUTH_TOKEN::"},
                {name:"CDX_SIGNATURE_SECRET_KEY", valueFrom:"\($secret_arn):CDX_SIGNATURE_SECRET_KEY::"},
                {name:"CDX_SENTRY_DSN", valueFrom:"\($secret_arn):CDX_SENTRY_DSN::"},
                {name:"CDX_DC", valueFrom:"\($secret_arn):CDX_DC::"},
                {name:"CDX_API_BASE", valueFrom:"\($secret_arn):CDX_API_BASE::"},
                {name:"CDX_LOGGING_S3_BUCKET", valueFrom:"\($secret_arn):CDX_LOGGING_S3_BUCKET::"}
            ],
            mountPoints: [{sourceVolume:"proxysql-data", containerPath:"/var/lib/proxysql", readOnly:false}],
            logConfiguration: {logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":$region, "awslogs-stream-prefix":"ecs"}}
        }]
    }')

# Add POSTGRES_PASSWORD + ENCRYPTION_KEY secrets if DAM
if [[ "$ENABLE_DAM" == "true" ]]; then
    PROXYSERVER_TD=$(echo "$PROXYSERVER_TD" | jq --arg sa "$SECRET_ARN" \
        '.containerDefinitions[0].secrets += [
            {name:"POSTGRES_PASSWORD", valueFrom:"\($sa):POSTGRES_PASSWORD::"},
            {name:"ENCRYPTION_KEY", valueFrom:"\($sa):ENCRYPTION_KEY::"}
        ]')
fi

echo "$PROXYSERVER_TD" > /tmp/td-proxyserver.json
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxyserver.json > /dev/null
ok "Task def: proxyserver-task"

# ---- ProxySQL Task Definition ----
PROXYSQL_TD=$(jq -n \
    --arg family "proxysql" \
    --arg image "$IMG_PROXYSQL" \
    --arg role "$ROLE_ARN" \
    --arg region "$AWS_REGION" \
    --arg lg "$LOG_GROUP_PROXYSQL" \
    --argjson volumes "$VOLUME_CONFIG" \
    '{
        family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
        cpu: "256", memory: "1024", executionRoleArn: $role, taskRoleArn: $role,
        volumes: $volumes,
        containerDefinitions: [{
            name: "proxysql",
            image: $image,
            cpu: 0, essential: true,
            portMappings: [
                {name:"proxysql-admin", containerPort:6032, hostPort:6032, protocol:"tcp"},
                {name:"proxysql-mysql", containerPort:6033, hostPort:6033, protocol:"tcp"}
            ],
            environment: [],
            mountPoints: [{sourceVolume:"proxysql-data", containerPath:"/var/lib/proxysql", readOnly:false}],
            logConfiguration: {logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":$region, "awslogs-stream-prefix":"ecs"}}
        }]
    }')
echo "$PROXYSQL_TD" > /tmp/td-proxysql.json
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxysql.json > /dev/null
ok "Task def: proxysql"

# ---- Query Logging Task Definition ----
QUERY_LOGGING_TD=$(jq -n \
    --arg family "query-logging-task" \
    --arg image "$IMG_QUERY_LOGGING" \
    --arg role "$ROLE_ARN" \
    --arg region "$AWS_REGION" \
    --arg lg "$LOG_GROUP_QUERY_LOGGING" \
    --arg secret_arn "$SECRET_ARN" \
    --argjson volumes "$VOLUME_CONFIG" \
    '{
        family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
        cpu: "256", memory: "1024", executionRoleArn: $role, taskRoleArn: $role,
        volumes: $volumes,
        containerDefinitions: [{
            name: "query-logging",
            image: $image,
            cpu: 0, essential: true,
            portMappings: [{name:"query-logging-port", containerPort:8079, hostPort:8079, protocol:"tcp", appProtocol:"http"}],
            environment: [
                {name:"AWS_DEFAULT_REGION", value:$region},
                {name:"CDX_APP_ENV", value:"production"},
                {name:"CDX_LOG_LEVEL", value:"DEBUG"},
                {name:"CDX_DEFAULT_REGION", value:$region},
                {name:"CDX_SERVER_VERSION", value:"1.0.0"}
            ],
            secrets: [
                {name:"CDX_AUTH_TOKEN", valueFrom:"\($secret_arn):CDX_AUTH_TOKEN::"},
                {name:"CDX_SIGNATURE_SECRET_KEY", valueFrom:"\($secret_arn):CDX_SIGNATURE_SECRET_KEY::"},
                {name:"CDX_SENTRY_DSN", valueFrom:"\($secret_arn):CDX_SENTRY_DSN::"},
                {name:"CDX_DC", valueFrom:"\($secret_arn):CDX_DC::"},
                {name:"CDX_API_BASE", valueFrom:"\($secret_arn):CDX_API_BASE::"},
                {name:"CDX_LOGGING_S3_BUCKET", valueFrom:"\($secret_arn):CDX_LOGGING_S3_BUCKET::"}
            ],
            mountPoints: [{sourceVolume:"proxysql-data", containerPath:"/var/lib/proxysql", readOnly:false}],
            logConfiguration: {logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":$region, "awslogs-stream-prefix":"ecs"}}
        }]
    }')

if [[ "$ENABLE_DAM" == "true" ]]; then
    QUERY_LOGGING_TD=$(echo "$QUERY_LOGGING_TD" | jq --arg sa "$SECRET_ARN" \
        '.containerDefinitions[0].secrets += [
            {name:"POSTGRES_PASSWORD", valueFrom:"\($sa):POSTGRES_PASSWORD::"},
            {name:"ENCRYPTION_KEY", valueFrom:"\($sa):ENCRYPTION_KEY::"}
        ]')
fi

echo "$QUERY_LOGGING_TD" > /tmp/td-query-logging.json
aws ecs register-task-definition --cli-input-json file:///tmp/td-query-logging.json > /dev/null
ok "Task def: query-logging-task"

# ---- DAM Task Definitions (if enabled) ----
if [[ "$ENABLE_DAM" == "true" ]]; then
    # DAM Server
    DAM_SERVER_TD=$(jq -n \
        --arg family "dam-server-task" \
        --arg image "$IMG_DAM_SERVER" \
        --arg role "$ROLE_ARN" \
        --arg region "$AWS_REGION" \
        --arg lg "$LOG_GROUP_DAM_SERVER" \
        --arg secret_arn "$SECRET_ARN" \
        --argjson volumes "$VOLUME_CONFIG" \
        '{
            family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
            cpu: "256", memory: "1024", executionRoleArn: $role, taskRoleArn: $role,
            volumes: $volumes,
            containerDefinitions: [{
                name: "dam-server",
                image: $image,
                cpu: 0, essential: true,
                portMappings: [{name:"dam-server-http", containerPort:8080, hostPort:8080, protocol:"tcp"}],
                environment: [
                    {name:"AWS_DEFAULT_REGION", value:$region},
                    {name:"NODE_ENV", value:"production"},
                    {name:"PROXYSERVER_HOST", value:"proxyserver"},
                    {name:"PROXYSERVER_PORT", value:"8079"},
                    {name:"DAM_LOG_LEVEL", value:"INFO"},
                    {name:"DAM_APP_ENV", value:"production"}
                ],
                secrets: [
                    {name:"CDX_AUTH_TOKEN", valueFrom:"\($secret_arn):CDX_AUTH_TOKEN::"},
                    {name:"CDX_SIGNATURE_SECRET_KEY", valueFrom:"\($secret_arn):CDX_SIGNATURE_SECRET_KEY::"},
                    {name:"CDX_SENTRY_DSN", valueFrom:"\($secret_arn):CDX_SENTRY_DSN::"},
                    {name:"CDX_DC", valueFrom:"\($secret_arn):CDX_DC::"},
                    {name:"CDX_API_BASE", valueFrom:"\($secret_arn):CDX_API_BASE::"},
                    {name:"POSTGRES_PASSWORD", valueFrom:"\($secret_arn):POSTGRES_PASSWORD::"}
                ],
                mountPoints: [{sourceVolume:"proxysql-data", containerPath:"/var/lib/proxysql", readOnly:false}],
                logConfiguration: {logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":$region, "awslogs-stream-prefix":"ecs"}}
            }]
        }')
    echo "$DAM_SERVER_TD" > /tmp/td-dam-server.json
    aws ecs register-task-definition --cli-input-json file:///tmp/td-dam-server.json > /dev/null
    ok "Task def: dam-server-task"

    # PostgreSQL
    POSTGRESQL_TD=$(jq -n \
        --arg family "postgresql-task" \
        --arg image "$IMG_POSTGRESQL" \
        --arg role "$ROLE_ARN" \
        --arg region "$AWS_REGION" \
        --arg lg "$LOG_GROUP_POSTGRESQL" \
        --arg secret_arn "$SECRET_ARN" \
        --argjson volumes "$VOLUME_CONFIG" \
        '{
            family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
            cpu: "256", memory: "1024", executionRoleArn: $role, taskRoleArn: $role,
            volumes: $volumes,
            containerDefinitions: [{
                name: "postgresql",
                image: $image,
                cpu: 0, essential: true,
                portMappings: [{name:"postgresql-db", containerPort:5432, hostPort:5432, protocol:"tcp"}],
                environment: [
                    {name:"POSTGRES_USER", value:"pgjitdbuser"},
                    {name:"POSTGRES_DB", value:"jitdb"},
                    {name:"PGDATA", value:"/var/lib/proxysql/postgresql/data/pgdata"},
                    {name:"POSTGRES_INITDB_ARGS", value:"-E UTF8 --locale=en_US.utf8"}
                ],
                secrets: [
                    {name:"POSTGRES_PASSWORD", valueFrom:"\($secret_arn):POSTGRES_PASSWORD::"}
                ],
                mountPoints: [{sourceVolume:"proxysql-data", containerPath:"/var/lib/proxysql", readOnly:false}],
                healthCheck: {command:["CMD-SHELL","pg_isready -U pgjitdbuser -d jitdb || exit 1"], interval:30, timeout:5, retries:3, startPeriod:60},
                logConfiguration: {logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":$region, "awslogs-stream-prefix":"ecs"}}
            }]
        }')
    echo "$POSTGRESQL_TD" > /tmp/td-postgresql.json
    aws ecs register-task-definition --cli-input-json file:///tmp/td-postgresql.json > /dev/null
    ok "Task def: postgresql-task"
fi

# =============================================================================
# ECS SERVICES
# =============================================================================

step "ECS Services"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}"

create_service() {
    local svc_name=$1 td=$2 count=$3 sc_config=$4
    EXISTING=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$svc_name" \
        --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text 2>/dev/null)
    if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
        ok "Service exists: $svc_name"
    else
        aws ecs create-service --cluster "$ECS_CLUSTER_NAME" \
            --service-name "$svc_name" \
            --task-definition "$td" \
            --desired-count "$count" \
            --launch-type FARGATE \
            --platform-version LATEST \
            --network-configuration "$NETWORK_CONFIG" \
            --enable-execute-command \
            --service-connect-configuration "$sc_config" \
            --tags $(cdx_tags_ecs) > /dev/null
        ok "Service created: $svc_name"
    fi
}

# ProxySQL service
create_service "proxysql" "proxysql" 1 \
    '{"enabled":true,"namespace":"proxysql-proxyserver","services":[{"portName":"proxysql-admin","discoveryName":"proxysql","clientAliases":[{"port":6032,"dnsName":"proxysql"}]}]}'

# ProxyServer service (2 replicas)
create_service "proxyserver" "proxyserver-task" 2 \
    '{"enabled":true,"namespace":"proxysql-proxyserver","services":[{"portName":"proxyserver-http","discoveryName":"proxyserver","clientAliases":[{"port":8079,"dnsName":"proxyserver"}]}]}'

# DAM: PostgreSQL first (query-logging depends on it)
if [[ "$ENABLE_DAM" == "true" ]]; then
    create_service "postgresql" "postgresql-task" 1 \
        '{"enabled":true,"namespace":"proxysql-proxyserver","services":[{"portName":"postgresql-db","discoveryName":"postgresql","clientAliases":[{"port":5432,"dnsName":"postgresql"}]}]}'
    info "Waiting for PostgreSQL service to stabilize..."
    aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services postgresql 2>/dev/null || true
fi

# Query Logging service
create_service "query-logging" "query-logging-task" 1 \
    '{"enabled":true,"namespace":"proxysql-proxyserver","services":[]}'

# DAM Server (after PostgreSQL)
if [[ "$ENABLE_DAM" == "true" ]]; then
    create_service "dam-server" "dam-server-task" 1 \
        '{"enabled":true,"namespace":"proxysql-proxyserver","services":[{"portName":"dam-server-http","discoveryName":"dam-server","clientAliases":[{"port":8080,"dnsName":"dam-server"}]}]}'
fi

info "Waiting for core services to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services proxysql proxyserver query-logging 2>/dev/null || true

if [[ "$ENABLE_DAM" == "true" ]]; then
    aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services dam-server postgresql 2>/dev/null || true
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Install workloads (existing VPC) complete"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:ECS_CLUSTER_ARN=${CLUSTER_ARN}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
echo "OUTPUT:EFS_ID=${EFS_ID}"
echo "OUTPUT:SECRET_ARN=${SECRET_ARN}"
echo "OUTPUT:PRIVATE_SUBNET_1_ID=${PRIVATE_SUBNET_1_ID}"
echo "OUTPUT:PRIVATE_SUBNET_2_ID=${PRIVATE_SUBNET_2_ID}"
echo "OUTPUT:NAMESPACE_ID=${NAMESPACE_ID}"
