#!/usr/bin/env bash
# =============================================================================
# Step: Install Workloads (Same Account — Additional Setup)
# =============================================================================
# Deploys a SECOND (or Nth) JIT DB setup in the same AWS account.
# Assumes the IAM role and base policies already exist from the first setup.
# Uses SETUP_NUMBER to suffix resource names for isolation.
#
# Key differences from first-time setup:
#   - Does NOT create IAM role or base policies
#   - Extends existing S3 and CloudWatch policies with new resources
#   - Suffixes: cluster, namespace, log groups, task families with -N
#
# Creates:
#   - CloudWatch Log Groups (suffixed per service)
#   - Secrets Manager secret
#   - S3 bucket for query logs
#   - Security group with self-referencing rules
#   - EFS filesystem with access point and mount targets
#   - ECS Cluster (Fargate, suffixed)
#   - Service Connect namespace (suffixed)
#   - Task definitions (suffixed families)
#   - ECS services with Service Connect
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, BUCKET_NAME, SECRET_NAME,
#   CDX_AUTH_TOKEN, CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN, CDX_DC,
#   CDX_API_BASE, ENABLE_DAM, IMAGE_TAG,
#   VPC_ID, PRIVATE_SUBNET_1_ID, PRIVATE_SUBNET_2_ID, SETUP_NUMBER
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:ECS_CLUSTER_ARN, OUTPUT:ECS_SG_ID, OUTPUT:EFS_ID,
#   OUTPUT:SECRET_ARN, OUTPUT:PRIVATE_SUBNET_1_ID, OUTPUT:PRIVATE_SUBNET_2_ID,
#   OUTPUT:NAMESPACE_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME BUCKET_NAME SECRET_NAME \
    CDX_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN CDX_DC CDX_API_BASE \
    ENABLE_DAM ENCRYPTION_KEY VPC_ID PRIVATE_SUBNET_1_ID PRIVATE_SUBNET_2_ID SETUP_NUMBER

IMAGE_TAG="${IMAGE_TAG:-latest}"

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
export AWS_DEFAULT_REGION="$AWS_REGION"

ROLE_NAME="${PROJECT_NAME}-ECSRole"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster-${SETUP_NUMBER}"
NAMESPACE_NAME="proxysql-proxyserver-${SETUP_NUMBER}"

# Suffixed log groups
LOG_GROUP_PROXYSERVER="/ecs/${PROJECT_NAME}/proxyserver-${SETUP_NUMBER}"
LOG_GROUP_PROXYSQL="/ecs/${PROJECT_NAME}/proxysql-${SETUP_NUMBER}"
LOG_GROUP_QUERY_LOGGING="/ecs/${PROJECT_NAME}/query-logging-${SETUP_NUMBER}"
LOG_GROUP_DAM_SERVER="/ecs/${PROJECT_NAME}/dam-server-${SETUP_NUMBER}"
LOG_GROUP_POSTGRESQL="/ecs/${PROJECT_NAME}/postgresql-${SETUP_NUMBER}"

# Suffixed task families
TD_PROXYSERVER="proxyserver-task-${SETUP_NUMBER}"
TD_PROXYSQL="proxysql-${SETUP_NUMBER}"
TD_QUERY_LOGGING="query-logging-task-${SETUP_NUMBER}"
TD_DAM_SERVER="dam-server-task-${SETUP_NUMBER}"
TD_POSTGRESQL="postgresql-task-${SETUP_NUMBER}"

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Project: $PROJECT_NAME"
info "Setup #${SETUP_NUMBER} | Cluster: $ECS_CLUSTER_NAME | Namespace: $NAMESPACE_NAME"
info "VPC: $VPC_ID | Subnets: $PRIVATE_SUBNET_1_ID, $PRIVATE_SUBNET_2_ID"

# EFS mount target DNS resolution requires VPC DNS hostnames + support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' 2>/dev/null || true
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' 2>/dev/null || true

# =============================================================================
# HELPER: EXTEND IAM POLICY
# =============================================================================
# Adds new resource ARNs to an existing policy's Statement[0].Resource array.
# Handles the 5-version limit by deleting the oldest non-default version.
# =============================================================================

extend_policy() {
    local policy_arn="$1"
    shift
    local new_resources=("$@")

    # Get current default version
    local default_version_id
    default_version_id=$(aws iam get-policy --policy-arn "$policy_arn" \
        --query 'Policy.DefaultVersionId' --output text)

    # Get current policy document
    local current_doc
    current_doc=$(aws iam get-policy-version --policy-arn "$policy_arn" \
        --version-id "$default_version_id" \
        --query 'PolicyVersion.Document' --output json)

    # URL-decode if necessary (AWS returns URL-encoded JSON sometimes)
    current_doc=$(echo "$current_doc" | python3 -c "import sys,json,urllib.parse; d=sys.stdin.read().strip(); print(urllib.parse.unquote(d) if d.startswith('%') else d)" 2>/dev/null || echo "$current_doc")

    # Build jq filter to add new resources (unique)
    local jq_filter='.Statement[0].Resource'
    # Ensure Resource is always an array
    local updated_doc
    updated_doc=$(echo "$current_doc" | jq --argjson new_res "$(printf '%s\n' "${new_resources[@]}" | jq -R . | jq -s .)" '
        .Statement[0].Resource = (
            if (.Statement[0].Resource | type) == "array" then
                .Statement[0].Resource
            else
                [.Statement[0].Resource]
            end
        ) |
        .Statement[0].Resource = (.Statement[0].Resource + $new_res | unique)
    ')

    # Handle 5-version limit: delete oldest non-default version if at limit
    local version_count
    version_count=$(aws iam list-policy-versions --policy-arn "$policy_arn" \
        --query 'length(Versions)' --output text)

    if [[ "$version_count" -ge 5 ]]; then
        # Find oldest non-default version
        local oldest_version
        oldest_version=$(aws iam list-policy-versions --policy-arn "$policy_arn" \
            --query "Versions[?IsDefaultVersion==\`false\`] | sort_by(@, &CreateDate) | [0].VersionId" \
            --output text)
        if [[ -n "$oldest_version" && "$oldest_version" != "None" ]]; then
            aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$oldest_version"
            info "Deleted old policy version: $oldest_version"
        fi
    fi

    # Create new default version
    aws iam create-policy-version --policy-arn "$policy_arn" \
        --policy-document "$updated_doc" \
        --set-as-default > /dev/null
}

# =============================================================================
# VERIFY IAM ROLE EXISTS
# =============================================================================

step "Verify IAM Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    error "IAM Role '$ROLE_NAME' does not exist. Run the first setup before adding additional setups."
    exit 1
fi
ok "IAM Role exists: $ROLE_NAME ($ROLE_ARN)"

# =============================================================================
# EXTEND EXISTING POLICIES
# =============================================================================

step "Extend Existing Policies"

# Extend S3 policy with new bucket ARNs
S3_POLICY_NAME="${PROJECT_NAME}-S3Access"
S3_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}"
if aws iam get-policy --policy-arn "$S3_POLICY_ARN" > /dev/null 2>&1; then
    extend_policy "$S3_POLICY_ARN" \
        "arn:aws:s3:::${BUCKET_NAME}" \
        "arn:aws:s3:::${BUCKET_NAME}/*"
    ok "Extended S3 policy with bucket: $BUCKET_NAME"
else
    warn "S3 policy '$S3_POLICY_NAME' not found — creating it"
    S3_POLICY_ARN=$(aws iam create-policy --policy-name "$S3_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:*\",\"s3-object-lambda:*\"],\"Resource\":[\"arn:aws:s3:::${BUCKET_NAME}\",\"arn:aws:s3:::${BUCKET_NAME}/*\"]}]}" \
        --query 'Policy.Arn' --output text)
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
fi

# Extend CloudWatch Logs policy with new log group ARNs
LOGS_POLICY_NAME="${PROJECT_NAME}-CloudWatchLogs"
LOGS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_POLICY_NAME}"
if aws iam get-policy --policy-arn "$LOGS_POLICY_ARN" > /dev/null 2>&1; then
    extend_policy "$LOGS_POLICY_ARN" \
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/proxyserver-${SETUP_NUMBER}:*" \
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/proxysql-${SETUP_NUMBER}:*" \
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/query-logging-${SETUP_NUMBER}:*" \
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/dam-server-${SETUP_NUMBER}:*" \
        "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/postgresql-${SETUP_NUMBER}:*"
    ok "Extended CloudWatch Logs policy for setup #${SETUP_NUMBER}"
else
    warn "CloudWatch Logs policy '$LOGS_POLICY_NAME' not found — creating it"
    LOG_ARNS="\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/ecs/${PROJECT_NAME}/*\""
    LOGS_POLICY_ARN=$(aws iam create-policy --policy-name "$LOGS_POLICY_NAME" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"logs:*\",\"cloudwatch:GenerateQuery\"],\"Resource\":[${LOG_ARNS}]}]}" \
        --query 'Policy.Arn' --output text)
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$LOGS_POLICY_ARN" 2>/dev/null || true
fi

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
ok "Log groups created (suffixed with -${SETUP_NUMBER})"

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
        --description "Secrets for CDX JIT DB (setup #${SETUP_NUMBER})" \
        --secret-string "$SECRET_JSON" \
        --tags "Key=Purpose,Value=database-iam-jit" "Key=created_by,Value=cloudanix" "Key=setup_number,Value=${SETUP_NUMBER}" \
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
SG_NAME="${PROJECT_NAME}-ecs-sg-${SETUP_NUMBER}"
ECS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$ECS_SG" || "$ECS_SG" == "None" ]]; then
    ECS_SG=$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description "Security group for ECS cluster (setup #${SETUP_NUMBER})" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=Purpose,Value=database-iam-jit},{Key=created_by,Value=cloudanix},{Key=setup_number,Value=${SETUP_NUMBER}}]" \
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
    ok "ECS SG created: $ECS_SG ($SG_NAME)"
else
    ok "ECS SG exists: $ECS_SG ($SG_NAME)"
fi

# =============================================================================
# EFS FILESYSTEM & ACCESS POINT
# =============================================================================

step "EFS"
EFS_NAME="${PROJECT_NAME}-efs-${SETUP_NUMBER}"
EFS_ID=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name'&&Value=='${EFS_NAME}']].FileSystemId | [0]" \
    --output text 2>/dev/null)
if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
    EFS_ID=$(aws efs create-file-system --performance-mode generalPurpose \
        --throughput-mode bursting --encrypted \
        --tags "Key=Name,Value=${EFS_NAME}" "Key=Purpose,Value=database-iam-jit" "Key=created_by,Value=cloudanix" "Key=setup_number,Value=${SETUP_NUMBER}" \
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

# Access point
ACCESS_POINT_ID=$(aws efs describe-access-points \
    --query "AccessPoints[?FileSystemId=='${EFS_ID}' && RootDirectory.Path=='/proxysql-data'].AccessPointId | [0]" \
    --output text 2>/dev/null)
if [[ -z "$ACCESS_POINT_ID" || "$ACCESS_POINT_ID" == "None" ]]; then
    ACCESS_POINT_ID=$(aws efs create-access-point --file-system-id "$EFS_ID" \
        --posix-user "Uid=1000,Gid=1000" \
        --root-directory "Path=/proxysql-data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=777}" \
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
        --tags "key=Purpose,value=database-iam-jit" "key=created_by,value=cloudanix" "key=setup_number,value=${SETUP_NUMBER}" \
        --query 'cluster.clusterArn' --output text)
    ok "Cluster created: $ECS_CLUSTER_NAME"
else
    ok "Cluster exists: $ECS_CLUSTER_NAME"
fi

# =============================================================================
# SERVICE CONNECT NAMESPACE
# =============================================================================

step "Service Connect Namespace"
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
    --arg family "$TD_PROXYSERVER" \
    --arg image "${ECR_PREFIX}/cloudanix/ecr-aws-jit-proxy-server:${IMAGE_TAG}" \
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
ok "Task def: $TD_PROXYSERVER"

# ---- ProxySQL Task Definition ----
PROXYSQL_TD=$(jq -n \
    --arg family "$TD_PROXYSQL" \
    --arg image "${ECR_PREFIX}/cloudanix/ecr-aws-jit-proxy-sql:${IMAGE_TAG}" \
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
ok "Task def: $TD_PROXYSQL"

# ---- Query Logging Task Definition ----
QUERY_LOGGING_TD=$(jq -n \
    --arg family "$TD_QUERY_LOGGING" \
    --arg image "${ECR_PREFIX}/cloudanix/ecr-aws-jit-query-logging:${IMAGE_TAG}" \
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
ok "Task def: $TD_QUERY_LOGGING"

# ---- DAM Task Definitions (if enabled) ----
if [[ "$ENABLE_DAM" == "true" ]]; then
    # DAM Server
    DAM_SERVER_TD=$(jq -n \
        --arg family "$TD_DAM_SERVER" \
        --arg image "${ECR_PREFIX}/cloudanix/ecr-aws-jit-dam-server:${IMAGE_TAG}" \
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
    ok "Task def: $TD_DAM_SERVER"

    # PostgreSQL
    POSTGRESQL_TD=$(jq -n \
        --arg family "$TD_POSTGRESQL" \
        --arg image "${ECR_PREFIX}/cloudanix/ecr-aws-jit-postgresql:${IMAGE_TAG}" \
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
    ok "Task def: $TD_POSTGRESQL"
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
            --tags "key=Purpose,value=database-iam-jit" "key=created_by,value=cloudanix" "key=setup_number,value=${SETUP_NUMBER}" > /dev/null
        ok "Service created: $svc_name"
    fi
}

# ProxySQL service
create_service "proxysql" "$TD_PROXYSQL" 1 \
    "{\"enabled\":true,\"namespace\":\"${NAMESPACE_NAME}\",\"services\":[{\"portName\":\"proxysql-admin\",\"discoveryName\":\"proxysql\",\"clientAliases\":[{\"port\":6032,\"dnsName\":\"proxysql\"}]}]}"

# ProxyServer service (2 replicas)
create_service "proxyserver" "$TD_PROXYSERVER" 2 \
    "{\"enabled\":true,\"namespace\":\"${NAMESPACE_NAME}\",\"services\":[{\"portName\":\"proxyserver-http\",\"discoveryName\":\"proxyserver\",\"clientAliases\":[{\"port\":8079,\"dnsName\":\"proxyserver\"}]}]}"

# DAM: PostgreSQL first (query-logging depends on it)
if [[ "$ENABLE_DAM" == "true" ]]; then
    create_service "postgresql" "$TD_POSTGRESQL" 1 \
        "{\"enabled\":true,\"namespace\":\"${NAMESPACE_NAME}\",\"services\":[{\"portName\":\"postgresql-db\",\"discoveryName\":\"postgresql\",\"clientAliases\":[{\"port\":5432,\"dnsName\":\"postgresql\"}]}]}"
    info "Waiting for PostgreSQL service to stabilize..."
    aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services postgresql 2>/dev/null || true
fi

# Query Logging service
create_service "query-logging" "$TD_QUERY_LOGGING" 1 \
    "{\"enabled\":true,\"namespace\":\"${NAMESPACE_NAME}\",\"services\":[]}"

# DAM Server (after PostgreSQL)
if [[ "$ENABLE_DAM" == "true" ]]; then
    create_service "dam-server" "$TD_DAM_SERVER" 1 \
        "{\"enabled\":true,\"namespace\":\"${NAMESPACE_NAME}\",\"services\":[{\"portName\":\"dam-server-http\",\"discoveryName\":\"dam-server\",\"clientAliases\":[{\"port\":8080,\"dnsName\":\"dam-server\"}]}]}"
fi

info "Waiting for core services to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services proxysql proxyserver query-logging 2>/dev/null || true

if [[ "$ENABLE_DAM" == "true" ]]; then
    aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services dam-server postgresql 2>/dev/null || true
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Install workloads (same account, setup #${SETUP_NUMBER}) complete"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:ECS_CLUSTER_ARN=${CLUSTER_ARN}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
echo "OUTPUT:EFS_ID=${EFS_ID}"
echo "OUTPUT:SECRET_ARN=${SECRET_ARN}"
echo "OUTPUT:PRIVATE_SUBNET_1_ID=${PRIVATE_SUBNET_1_ID}"
echo "OUTPUT:PRIVATE_SUBNET_2_ID=${PRIVATE_SUBNET_2_ID}"
echo "OUTPUT:NAMESPACE_ID=${NAMESPACE_ID}"
