# =============================================================================
# Step: Install VM Workloads (New VPC)
# =============================================================================
# Creates the full JIT VM infrastructure in a new VPC: VPC, public/private
# subnets (multi-AZ), IGW, NAT, security groups, VPC endpoints (SSM), S3 bucket,
# IAM role + task policy, CloudWatch log group, Secrets Manager app secret,
# EFS + mount targets + access points, Cloud Map namespace, ECS cluster with
# Service Connect, 3 task definitions, and 3 ECS services.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME, VPC_CIDR, S3_BUCKET_NAME,
#   CDX_API_AUTH_TOKEN, CDX_SIGNATURE_SECRET_KEY, CDX_SENTRY_DSN,
#   CDX_DATA_CENTER, CDX_API_BASE
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:VPC_CIDR, OUTPUT:ECS_SG_ID, OUTPUT:CLUSTER_NAME,
#   OUTPUT:EFS_ID, OUTPUT:PRIVATE_SUBNET_1_ID, OUTPUT:PRIVATE_SUBNET_2_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
export CDX_PURPOSE=jit_vm

require_env AWS_REGION PROJECT_NAME VPC_CIDR S3_BUCKET_NAME \
    CDX_API_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY CDX_SENTRY_DSN \
    CDX_DATA_CENTER CDX_API_BASE

# =============================================================================
# DERIVED CONFIGURATION
# =============================================================================

export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PUB_SUB_1_CIDR="${VPC_BASE}.1.0/24"
PUB_SUB_2_CIDR="${VPC_BASE}.2.0/24"
PRIV_SUB_1_CIDR="${VPC_BASE}.3.0/24"
PRIV_SUB_2_CIDR="${VPC_BASE}.4.0/24"
AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)
CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT_NAME}-cluster}"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
NAMESPACE="${PROJECT_NAME}-local"
ECR_PREFIX="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Pinned VM image tag + per-service image URIs (honors ECR sourcing mode).
IMAGE_TAG="${IMAGE_TAG:-${CDX_VM_IMAGE_TAG:-v0.3.31}}"
IMG_SSHPIPER=$(cdx_image_uri "vm-sshpiper" "$IMAGE_TAG")
IMG_VM_PROXYSERVER=$(cdx_image_uri "vm-proxyserver" "$IMAGE_TAG")
IMG_VM_LOGGING=$(cdx_image_uri "vm-logging" "$IMAGE_TAG")

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Project: $PROJECT_NAME"
info "VPC CIDR: $VPC_CIDR | AZs: $AZ_1, $AZ_2"
info "Image source mode: ${CDX_ECR_MODE:-pull-through} | tag: $IMAGE_TAG"

# =============================================================================
# ECR PULL-THROUGH CACHE (default image sourcing)
# =============================================================================
if [[ "${CDX_ECR_MODE:-pull-through}" != "sync" ]]; then
    step "ECR Pull-Through Cache"
    cdx_ensure_pull_through_cache
fi

# =============================================================================
# VPC
# =============================================================================

step "VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" "Name=cidr,Values=${VPC_CIDR}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-vpc},")]" \
        --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi

IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-igw},")]" \
        --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi

# =============================================================================
# SUBNETS (2 public + 2 private across 2 AZs)
# =============================================================================

step "Subnets (multi-AZ)"
find_or_create_subnet() {
    local cidr=$1 az=$2 name=$3
    local sid
    sid=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$sid" || "$sid" == "None" ]]; then
        sid=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${name}},")]" \
            --query 'Subnet.SubnetId' --output text)
    fi
    echo "$sid"
}

PUB_SUB_1=$(find_or_create_subnet "$PUB_SUB_1_CIDR" "$AZ_1" "${PROJECT_NAME}-public-1")
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUB_1" --map-public-ip-on-launch 2>/dev/null || true
PUB_SUB_2=$(find_or_create_subnet "$PUB_SUB_2_CIDR" "$AZ_2" "${PROJECT_NAME}-public-2")
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUB_2" --map-public-ip-on-launch 2>/dev/null || true
PRIV_SUB_1=$(find_or_create_subnet "$PRIV_SUB_1_CIDR" "$AZ_1" "${PROJECT_NAME}-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$PRIV_SUB_2_CIDR" "$AZ_2" "${PROJECT_NAME}-private-2")
ok "Public: $PUB_SUB_1,$PUB_SUB_2 | Private: $PRIV_SUB_1,$PRIV_SUB_2"

# =============================================================================
# NAT GATEWAY + ROUTE TABLES
# =============================================================================

step "NAT Gateway"
NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
if [[ -z "$NAT_ID" || "$NAT_ID" == "None" ]]; then
    EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP" \
        --tag-specifications "ResourceType=natgateway,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-nat},")]" \
        --query 'NatGateway.NatGatewayId' --output text)
    info "Waiting for NAT Gateway..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
    ok "NAT created: $NAT_ID"
else
    ok "NAT exists: $NAT_ID"
fi

step "Route Tables"
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-pub-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-pub-rt},")]" \
        --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_1" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_2" > /dev/null
fi
PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT_NAME}-priv-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [[ -z "$PRIV_RT" || "$PRIV_RT" == "None" ]]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-priv-rt},")]" \
        --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_1" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_2" > /dev/null
fi
ok "Route tables configured"

# =============================================================================
# SECURITY GROUPS
# =============================================================================

step "Security Groups"
ECS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$ECS_SG" || "$ECS_SG" == "None" ]]; then
    ECS_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-ecs-sg" \
        --description "ECS tasks - sshpiper(2222), proxyserver(8079), NFS(2049)" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-ecs-sg},")]" \
        --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2222 --cidr "$VPC_CIDR" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8079 --cidr "$VPC_CIDR" > /dev/null
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG" > /dev/null
fi
VPCE_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT_NAME}-vpce-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$VPCE_SG" || "$VPCE_SG" == "None" ]]; then
    VPCE_SG=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-vpce-sg" \
        --description "VPC Endpoints - HTTPS from VPC" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-vpce-sg},")]" \
        --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --group-id "$VPCE_SG" --protocol tcp --port 443 --cidr "$VPC_CIDR" > /dev/null
fi
ok "ECS SG: $ECS_SG | VPCE SG: $VPCE_SG"

# =============================================================================
# VPC ENDPOINTS (SSM for ECS Exec)
# =============================================================================

step "VPC Endpoints (SSM)"
for SVC in ssm ssmmessages ec2messages; do
    EXISTING_VPCE=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.${SVC}" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)
    if [[ -z "$EXISTING_VPCE" || "$EXISTING_VPCE" == "None" ]]; then
        aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
            --service-name "com.amazonaws.${AWS_REGION}.${SVC}" \
            --subnet-ids "$PRIV_SUB_1" "$PRIV_SUB_2" \
            --security-group-ids "$VPCE_SG" --private-dns-enabled \
            --tag-specifications "ResourceType=vpc-endpoint,Tags=[$(cdx_tags_ec2 "{Key=Name,Value=${PROJECT_NAME}-${SVC}},")]" \
            --query 'VpcEndpoint.VpcEndpointId' --output text > /dev/null
        info "  $SVC: created"
    else
        info "  $SVC: exists"
    fi
done
ok "VPC endpoints ready"

# =============================================================================
# S3 BUCKET (session recordings)
# =============================================================================

step "S3 Bucket"
if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null >/dev/null; then
    ok "S3 exists: $S3_BUCKET_NAME"
else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
    ok "S3 created: $S3_BUCKET_NAME"
fi
aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --versioning-configuration Status=Enabled 2>/dev/null || true
aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' 2>/dev/null || true
aws s3api put-bucket-tagging --bucket "$S3_BUCKET_NAME" \
    --tagging "TagSet=[$(cdx_tags_ec2)]" 2>/dev/null || true

# =============================================================================
# IAM ROLE (single role for execution + task)
# =============================================================================

step "IAM Role"
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
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

# ECR pull-through cache permissions (default image sourcing).
if [[ "${CDX_ECR_MODE:-pull-through}" != "sync" ]]; then
    cdx_attach_pull_through_iam "$ROLE_NAME"
fi

cat > /tmp/vm-task-policy.json << EOF
{
    "Version":"2012-10-17",
    "Statement":[
        {"Sid":"ECSExec","Effect":"Allow","Action":["ssmmessages:CreateControlChannel","ssmmessages:CreateDataChannel","ssmmessages:OpenControlChannel","ssmmessages:OpenDataChannel"],"Resource":"*"},
        {"Sid":"SecretsManager","Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":"arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${PROJECT_NAME}*"},
        {"Sid":"S3Recordings","Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::${S3_BUCKET_NAME}","arn:aws:s3:::${S3_BUCKET_NAME}/*"]},
        {"Sid":"CloudWatchLogs","Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"],"Resource":"*"},
        {"Sid":"EFSAccess","Effect":"Allow","Action":["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"],"Resource":"*"},
        {"Sid":"AssumeRole","Effect":"Allow","Action":"sts:AssumeRole","Resource":"*"}
    ]
}
EOF
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT_NAME}-task-policy" \
    --policy-document file:///tmp/vm-task-policy.json
ok "Task policy attached"
info "Waiting for IAM propagation..."
sleep 10

# =============================================================================
# CLOUDWATCH LOG GROUP
# =============================================================================

step "CloudWatch Log Group"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30 2>/dev/null || true
aws logs tag-log-group --log-group-name "$LOG_GROUP" --tags "Environment=Prod,Created_by=Cloudanix,purpose=jit_vm,aws-apn-id=${CDX_APN_ID}" 2>/dev/null || true
ok "Log group: $LOG_GROUP"

# =============================================================================
# SECRETS MANAGER (app config)
# =============================================================================

step "Secrets Manager (app config)"
APP_SECRET_NAME="${PROJECT_NAME}-secret"
# Always build the secret JSON from the current config so its keys match what
# the task definitions reference (CDX_DATA_CENTER, CDX_DC, ...). Then create the
# secret if missing OR overwrite an existing one — a secret left over from an
# earlier run may lack keys the containers require, which fails task startup
# with "secret ... did not contain json key CDX_DATA_CENTER".
SECRET_JSON=$(jq -n \
    --arg token "$CDX_API_AUTH_TOKEN" \
    --arg sig "$CDX_SIGNATURE_SECRET_KEY" \
    --arg sentry "$CDX_SENTRY_DSN" \
    --arg dc "$CDX_DATA_CENTER" \
    --arg api_base "$CDX_API_BASE" \
    '{CDX_API_AUTH_TOKEN:$token, CDX_SIGNATURE_SECRET_KEY:$sig, CDX_SENTRY_DSN:$sentry, CDX_DATA_CENTER:$dc, CDX_DC:$dc, CDX_API_BASE:$api_base}')
APP_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$APP_SECRET_NAME" --query 'ARN' --output text 2>/dev/null) || APP_SECRET_ARN=""
if [[ -z "$APP_SECRET_ARN" ]]; then
    APP_SECRET_ARN=$(aws secretsmanager create-secret --name "$APP_SECRET_NAME" \
        --description "App secrets for ${PROJECT_NAME} containers" \
        --secret-string "$SECRET_JSON" \
        --tags $(cdx_tags_kv) \
        --query 'ARN' --output text)
    ok "Secret created: $APP_SECRET_NAME"
else
    aws secretsmanager put-secret-value --secret-id "$APP_SECRET_NAME" \
        --secret-string "$SECRET_JSON" > /dev/null
    ok "Secret updated: $APP_SECRET_NAME (refreshed keys)"
fi

# =============================================================================
# EFS (shared volume: sshpiper workingdir + recordings)
# =============================================================================

step "EFS File System"
create_efs() {
    local _id
    _id=$(aws efs create-file-system --performance-mode generalPurpose \
        --throughput-mode bursting --encrypted \
        --tags "Key=Name,Value=${PROJECT_NAME}-efs" $(cdx_tags_kv) \
        --query 'FileSystemId' --output text)
    info "Waiting for EFS..."
    for _i in $(seq 1 20); do
        local _state
        _state=$(aws efs describe-file-systems --file-system-id "$_id" \
            --query 'FileSystems[0].LifeCycleState' --output text)
        [[ "$_state" == "available" ]] && break
        sleep 5
    done
    echo "$_id"
}

# Find an EFS tagged for this project that is USABLE in the current VPC.
# EFS mount targets are VPC-scoped: an EFS whose mount targets live in another
# VPC cannot get a mount target here (MountTargetConflict). There may be more
# than one name-matching EFS (e.g. an orphan from a prior run in a deleted VPC),
# so we scan all of them and pick one that has no mount targets yet OR already
# has them in $VPC_ID. If none qualifies, we create a fresh EFS.
EFS_ID=""
CANDIDATE_EFS_IDS=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-efs']].FileSystemId" \
    --output text 2>/dev/null)
for _efs in $CANDIDATE_EFS_IDS; do
    [[ -z "$_efs" || "$_efs" == "None" ]] && continue
    _mt_subnet=$(aws efs describe-mount-targets --file-system-id "$_efs" \
        --query 'MountTargets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$_mt_subnet" || "$_mt_subnet" == "None" ]]; then
        # No mount targets yet — usable in any VPC.
        EFS_ID="$_efs"
        ok "EFS exists: $EFS_ID (no mount targets yet)"
        break
    fi
    _mt_vpc=$(aws ec2 describe-subnets --subnet-ids "$_mt_subnet" \
        --query 'Subnets[0].VpcId' --output text 2>/dev/null) || _mt_vpc=""
    if [[ "$_mt_vpc" == "$VPC_ID" ]]; then
        EFS_ID="$_efs"
        ok "EFS exists: $EFS_ID (mount targets in current VPC)"
        break
    fi
    info "Skipping EFS $_efs — mount targets in different VPC (${_mt_vpc:-unknown})"
done
if [[ -z "$EFS_ID" ]]; then
    EFS_ID=$(create_efs)
    ok "EFS created: $EFS_ID"
fi

for SUB in "$PRIV_SUB_1" "$PRIV_SUB_2"; do
    EXISTING_MT=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query "MountTargets[?SubnetId=='${SUB}'].MountTargetId | [0]" --output text 2>/dev/null)
    if [[ -z "$EXISTING_MT" || "$EXISTING_MT" == "None" ]]; then
        aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUB" \
            --security-groups "$ECS_SG" > /dev/null
    fi
done
info "Waiting for mount targets to become available..."
for _i in $(seq 1 40); do
    NOT_READY=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query "length(MountTargets[?LifeCycleState!='available'])" --output text 2>/dev/null)
    [[ "$NOT_READY" == "0" ]] && break
    sleep 5
done
ok "EFS mount targets available"

SSHPIPER_AP=$(aws efs describe-access-points --file-system-id "$EFS_ID" \
    --query "AccessPoints[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-sshpiper-ap']].AccessPointId | [0]" --output text 2>/dev/null)
if [[ -z "$SSHPIPER_AP" || "$SSHPIPER_AP" == "None" ]]; then
    SSHPIPER_AP=$(aws efs create-access-point --file-system-id "$EFS_ID" \
        --posix-user "Uid=0,Gid=0" \
        --root-directory "Path=/sshpiper,CreationInfo={OwnerUid=0,OwnerGid=0,Permissions=0777}" \
        --tags "Key=Name,Value=${PROJECT_NAME}-sshpiper-ap" $(cdx_tags_kv) \
        --query 'AccessPointId' --output text)
fi
RECORDINGS_AP=$(aws efs describe-access-points --file-system-id "$EFS_ID" \
    --query "AccessPoints[?Tags[?Key=='Name'&&Value=='${PROJECT_NAME}-recordings-ap']].AccessPointId | [0]" --output text 2>/dev/null)
if [[ -z "$RECORDINGS_AP" || "$RECORDINGS_AP" == "None" ]]; then
    RECORDINGS_AP=$(aws efs create-access-point --file-system-id "$EFS_ID" \
        --posix-user "Uid=0,Gid=0" \
        --root-directory "Path=/recordings,CreationInfo={OwnerUid=0,OwnerGid=0,Permissions=0777}" \
        --tags "Key=Name,Value=${PROJECT_NAME}-recordings-ap" $(cdx_tags_kv) \
        --query 'AccessPointId' --output text)
fi
ok "EFS: $EFS_ID (sshpiper-ap: $SSHPIPER_AP, recordings-ap: $RECORDINGS_AP)"

# =============================================================================
# CLOUD MAP NAMESPACE
# =============================================================================

step "Cloud Map Namespace"
NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --filters "Name=NAME,Values=${NAMESPACE}" --query 'Namespaces[0].Id' --output text 2>/dev/null)
if [[ -z "$NAMESPACE_ID" || "$NAMESPACE_ID" == "None" ]]; then
    OPERATION_ID=$(aws servicediscovery create-private-dns-namespace \
        --name "$NAMESPACE" --vpc "$VPC_ID" \
        --description "Service discovery for ${PROJECT_NAME}" \
        --query 'OperationId' --output text)
    info "Waiting for namespace creation..."
    for _i in $(seq 1 36); do
        OP_STATUS=$(aws servicediscovery get-operation --operation-id "$OPERATION_ID" \
            --query 'Operation.Status' --output text 2>/dev/null)
        [[ "$OP_STATUS" == "SUCCESS" ]] && break
        if [[ "$OP_STATUS" == "FAIL" ]]; then error "Namespace creation failed"; exit 1; fi
        sleep 5
    done
    NAMESPACE_ID=$(aws servicediscovery list-namespaces \
        --filters "Name=NAME,Values=${NAMESPACE}" --query 'Namespaces[0].Id' --output text)
    ok "Namespace created: $NAMESPACE ($NAMESPACE_ID)"
else
    ok "Namespace exists: $NAMESPACE ($NAMESPACE_ID)"
fi

# =============================================================================
# ECS CLUSTER (Service Connect)
# =============================================================================

step "ECS Cluster"
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
sleep 10
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
    --query 'clusters[0].status' --output text 2>/dev/null)
if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
    aws ecs update-cluster --cluster "$CLUSTER_NAME" \
        --service-connect-defaults "namespace=arn:aws:servicediscovery:${AWS_REGION}:${ACCOUNT_ID}:namespace/${NAMESPACE_ID}" > /dev/null 2>&1 || true
    ok "Cluster exists: $CLUSTER_NAME"
else
    CLUSTER_CREATED=false
    for attempt in 1 2 3; do
        if aws ecs create-cluster --cluster-name "$CLUSTER_NAME" \
            --capacity-providers FARGATE \
            --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
            --configuration "executeCommandConfiguration={logging=DEFAULT}" \
            --service-connect-defaults "namespace=arn:aws:servicediscovery:${AWS_REGION}:${ACCOUNT_ID}:namespace/${NAMESPACE_ID}" \
            --tags $(cdx_tags_ecs) > /dev/null 2>&1; then
            CLUSTER_CREATED=true; break
        fi
        info "ECS SLR not ready, retrying in 15s ($attempt/3)..."
        sleep 15
    done
    [[ "$CLUSTER_CREATED" == false ]] && { error "Failed to create ECS cluster"; exit 1; }
    ok "Cluster created: $CLUSTER_NAME"
fi

# =============================================================================
# TASK DEFINITIONS
# =============================================================================

step "Task Definitions"
EFS_VOLUMES='[{"name":"sshpiper-workingdir","efsVolumeConfiguration":{"fileSystemId":"'$EFS_ID'","transitEncryption":"ENABLED","authorizationConfig":{"accessPointId":"'$SSHPIPER_AP'","iam":"ENABLED"}}},{"name":"sshpiper-recordings","efsVolumeConfiguration":{"fileSystemId":"'$EFS_ID'","transitEncryption":"ENABLED","authorizationConfig":{"accessPointId":"'$RECORDINGS_AP'","iam":"ENABLED"}}}]'
TD_TAGS=$(cdx_tags_json_lc)

cat > /tmp/td-sshpiper.json << EOF
{
    "family": "${PROJECT_NAME}-sshpiper", "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
    "cpu": "256", "memory": "512", "executionRoleArn": "${ROLE_ARN}", "taskRoleArn": "${ROLE_ARN}",
    "volumes": ${EFS_VOLUMES},
    "containerDefinitions": [{
        "name": "sshpiper", "image": "${IMG_SSHPIPER}", "essential": true,
        "portMappings": [{"name":"sshpiper","containerPort":2222,"protocol":"tcp"}],
        "mountPoints": [
            {"sourceVolume":"sshpiper-workingdir","containerPath":"/tmp/sshpiper/workingdir","readOnly":false},
            {"sourceVolume":"sshpiper-recordings","containerPath":"/tmp/recordings","readOnly":false}
        ],
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"sshpiper"}}
    }],
    "tags": ${TD_TAGS}
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-sshpiper.json > /dev/null
ok "Task def: ${PROJECT_NAME}-sshpiper"

cat > /tmp/td-proxyserver.json << EOF
{
    "family": "${PROJECT_NAME}-vmproxyserver", "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
    "cpu": "512", "memory": "1024", "executionRoleArn": "${ROLE_ARN}", "taskRoleArn": "${ROLE_ARN}",
    "volumes": ${EFS_VOLUMES},
    "containerDefinitions": [{
        "name": "vmproxyserver", "image": "${IMG_VM_PROXYSERVER}", "essential": true,
        "portMappings": [{"name":"vmproxyserver","containerPort":8079,"protocol":"tcp"}],
        "mountPoints": [
            {"sourceVolume":"sshpiper-workingdir","containerPath":"/tmp/sshpiper/workingdir","readOnly":false},
            {"sourceVolume":"sshpiper-recordings","containerPath":"/tmp/recordings","readOnly":false}
        ],
        "environment": [
            {"name":"CDX_ENVIRONMENT","value":"production"},
            {"name":"CDX_DEFAULT_REGION","value":"${AWS_REGION}"},
            {"name":"CDX_LOG_LEVEL","value":"DEBUG"},
            {"name":"CDX_VM_PROXY_VERSION","value":"1.0.0"},
            {"name":"CDX_VM_LOG_MANAGER_VERSION","value":"1.0.0"},
            {"name":"CDX_VM_LOGGING_S3_BUCKET","value":"${S3_BUCKET_NAME}"},
            {"name":"CDX_VM_SECRETS_MANAGER_NAME","value":"${PROJECT_NAME}-ssh-keys"},
            {"name":"AWS_STS_REGIONAL_ENDPOINTS","value":"regional"}
        ],
        "secrets": [
            {"name":"CDX_API_AUTH_TOKEN","valueFrom":"${APP_SECRET_ARN}:CDX_API_AUTH_TOKEN::"},
            {"name":"CDX_SIGNATURE_SECRET_KEY","valueFrom":"${APP_SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name":"CDX_SENTRY_DSN","valueFrom":"${APP_SECRET_ARN}:CDX_SENTRY_DSN::"},
            {"name":"CDX_DATA_CENTER","valueFrom":"${APP_SECRET_ARN}:CDX_DATA_CENTER::"},
            {"name":"CDX_DC","valueFrom":"${APP_SECRET_ARN}:CDX_DC::"},
            {"name":"CDX_API_BASE","valueFrom":"${APP_SECRET_ARN}:CDX_API_BASE::"}
        ],
        "healthCheck": {"command":["CMD-SHELL","pgrep -f 'python.*main.py' || exit 1"],"interval":30,"timeout":5,"retries":3,"startPeriod":15},
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"vmproxyserver"}}
    }],
    "tags": ${TD_TAGS}
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-proxyserver.json > /dev/null
ok "Task def: ${PROJECT_NAME}-vmproxyserver"

cat > /tmp/td-logging.json << EOF
{
    "family": "${PROJECT_NAME}-vmcommandlogging", "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
    "cpu": "256", "memory": "512", "executionRoleArn": "${ROLE_ARN}", "taskRoleArn": "${ROLE_ARN}",
    "volumes": ${EFS_VOLUMES},
    "containerDefinitions": [{
        "name": "vmcommandlogging", "image": "${IMG_VM_LOGGING}", "essential": true,
        "mountPoints": [
            {"sourceVolume":"sshpiper-workingdir","containerPath":"/tmp/sshpiper/workingdir","readOnly":false},
            {"sourceVolume":"sshpiper-recordings","containerPath":"/tmp/recordings","readOnly":false}
        ],
        "environment": [
            {"name":"CDX_ENVIRONMENT","value":"production"},
            {"name":"CDX_DEFAULT_REGION","value":"${AWS_REGION}"},
            {"name":"CDX_LOG_LEVEL","value":"INFO"},
            {"name":"CDX_VM_LOG_MANAGER_VERSION","value":"1.0.0"},
            {"name":"CDX_VM_LOGGING_S3_BUCKET","value":"${S3_BUCKET_NAME}"},
            {"name":"AWS_STS_REGIONAL_ENDPOINTS","value":"regional"}
        ],
        "secrets": [
            {"name":"CDX_API_AUTH_TOKEN","valueFrom":"${APP_SECRET_ARN}:CDX_API_AUTH_TOKEN::"},
            {"name":"CDX_SIGNATURE_SECRET_KEY","valueFrom":"${APP_SECRET_ARN}:CDX_SIGNATURE_SECRET_KEY::"},
            {"name":"CDX_SENTRY_DSN","valueFrom":"${APP_SECRET_ARN}:CDX_SENTRY_DSN::"},
            {"name":"CDX_DATA_CENTER","valueFrom":"${APP_SECRET_ARN}:CDX_DATA_CENTER::"},
            {"name":"CDX_DC","valueFrom":"${APP_SECRET_ARN}:CDX_DC::"},
            {"name":"CDX_API_BASE","valueFrom":"${APP_SECRET_ARN}:CDX_API_BASE::"}
        ],
        "healthCheck": {"command":["CMD-SHELL","pgrep -f 'python.*commandlogmanager' || exit 1"],"interval":30,"timeout":5,"retries":3,"startPeriod":15},
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {"logDriver":"awslogs","options":{"awslogs-group":"${LOG_GROUP}","awslogs-region":"${AWS_REGION}","awslogs-stream-prefix":"vmcommandlogging"}}
    }],
    "tags": ${TD_TAGS}
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td-logging.json > /dev/null
ok "Task def: ${PROJECT_NAME}-vmcommandlogging"

# =============================================================================
# ECS SERVICES (Service Connect)
# =============================================================================

step "ECS Services"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$PRIV_SUB_1,$PRIV_SUB_2],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}"
NS_ARN="arn:aws:servicediscovery:${AWS_REGION}:${ACCOUNT_ID}:namespace/${NAMESPACE_ID}"
SC_SSHPIPER='{"enabled":true,"namespace":"'$NS_ARN'","services":[{"portName":"sshpiper","discoveryName":"sshpiper","clientAliases":[{"port":2222,"dnsName":"sshpiper.'$NAMESPACE'"}]}]}'
SC_VMPROXY='{"enabled":true,"namespace":"'$NS_ARN'","services":[{"portName":"vmproxyserver","discoveryName":"vmproxyserver","clientAliases":[{"port":8079,"dnsName":"vmproxyserver.'$NAMESPACE'"}]}]}'
SC_LOGGING='{"enabled":true,"namespace":"'$NS_ARN'"}'

create_or_skip_service() {
    local svc_name=$1 task_def=$2 sc_config=$3
    local existing
    existing=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc_name" \
        --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text 2>/dev/null)
    if [[ -n "$existing" && "$existing" != "None" ]]; then
        ok "Service exists: $svc_name"
    else
        aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc_name" \
            --task-definition "$task_def" --desired-count 1 --launch-type FARGATE \
            --enable-execute-command --network-configuration "$NETWORK_CONFIG" \
            --service-connect-configuration "$sc_config" \
            --tags $(cdx_tags_ecs) > /dev/null
        ok "Service created: $svc_name"
    fi
}

create_or_skip_service "jit-vm-proxy-sshpiper" "${PROJECT_NAME}-sshpiper" "$SC_SSHPIPER"
create_or_skip_service "jit-vm-proxy-vmproxyserver" "${PROJECT_NAME}-vmproxyserver" "$SC_VMPROXY"
create_or_skip_service "jit-vm-proxy-vmcommandlogging" "${PROJECT_NAME}-vmcommandlogging" "$SC_LOGGING"

info "Waiting for services to stabilize..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" \
    --services jit-vm-proxy-sshpiper jit-vm-proxy-vmproxyserver jit-vm-proxy-vmcommandlogging 2>/dev/null || true

# Cleanup temp files
rm -f /tmp/vm-task-policy.json /tmp/td-sshpiper.json /tmp/td-proxyserver.json /tmp/td-logging.json

# =============================================================================
# OUTPUT
# =============================================================================

ok "VM workload infrastructure deployed"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:VPC_CIDR=${VPC_CIDR}"
echo "OUTPUT:ECS_SG_ID=${ECS_SG}"
echo "OUTPUT:CLUSTER_NAME=${CLUSTER_NAME}"
echo "OUTPUT:EFS_ID=${EFS_ID}"
echo "OUTPUT:PRIVATE_SUBNET_1_ID=${PRIV_SUB_1}"
echo "OUTPUT:PRIVATE_SUBNET_2_ID=${PRIV_SUB_2}"
