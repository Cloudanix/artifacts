#!/usr/bin/env bash
# =============================================================================
# AWS JIT Database — Cleanup Script (discovery-based, state file optional)
# =============================================================================
# Tears down JIT DB resources by DISCOVERING them via well-known names and
# tags. Works with or without .state.json — state is used only for hints
# (region, project name, bucket, DB account).
#
# Fixed names (PROJECT_NAME defaults to cdx-jit-db):
#   ECS cluster        : <project>-cluster
#   Services           : proxysql, proxyserver, query-logging, postgresql, dam-server
#   IAM role           : <project>-ECSRole
#   Custom policies    : <project>-SecretsAccess/-EFSAccess/-S3Access/-CloudWatchLogs
#   EFS                : tag Name=<project>-efs
#   VPC (new-vpc)      : tag Name=<project>-vpc
#   Namespace          : proxysql-proxyserver
#   Log group          : /ecs/<project>
#
# Called by: setup.sh --cleanup
# =============================================================================

_STATE="${STATE_FILE:-}"
get_cfg() { [[ -f "$_STATE" ]] && jq -r --arg k "$1" '.config[$k] // ""' "$_STATE" 2>/dev/null || echo ""; }
get_out() { [[ -f "$_STATE" ]] && jq -r --arg k "$1" '[.steps[]?|select(.status=="complete")|.outputs//{}|to_entries[]]|.[]|select(.key==$k)|.value' "$_STATE" 2>/dev/null || echo ""; }

AWS_REGION="$(get_cfg AWS_REGION)"
[[ -z "$AWS_REGION" ]] && AWS_REGION="$(aws configure get region 2>/dev/null || echo us-east-1)"
export AWS_DEFAULT_REGION="$AWS_REGION"

PROJECT_NAME="$(get_cfg PROJECT_NAME)"; [[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="cdx-jit-db"
SCOPE_MODE="$(jq -r '.scope_mode // ""' "$_STATE" 2>/dev/null || echo "")"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Bucket/secret names may be customized; use state hints if present
BUCKET_NAME="$(get_cfg BUCKET_NAME)"
SECRET_NAME="$(get_cfg SECRET_NAME)"; [[ -z "$SECRET_NAME" ]] && SECRET_NAME="CDX_SECRETS"

CLUSTER_NAME="${PROJECT_NAME}-cluster"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
NAMESPACE_NAME="proxysql-proxyserver"

info "Region: $AWS_REGION | Project: $PROJECT_NAME | Account: $ACCOUNT_ID"
info "Scope hint: ${SCOPE_MODE:-<none>}"

# =============================================================================
# DISCOVER ALL SETUPS: base cluster + numbered (cdx-jit-db-cluster, -cluster-2, ...)
# =============================================================================

# Find all clusters whose name starts with the base cluster name
ALL_CLUSTERS=$(aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null \
    | tr '\t' '\n' | awk -F/ '{print $NF}' | grep -E "^${CLUSTER_NAME}(-[0-9]+)?$" || echo "")

if [[ -z "$ALL_CLUSTERS" ]]; then
    ALL_CLUSTERS="$CLUSTER_NAME"
fi
info "Clusters to clean: $(echo $ALL_CLUSTERS | tr '\n' ' ')"

# =============================================================================
# 1. DELETE ECS SERVICES (across all setups)
# =============================================================================

step "ECS Services"
for CN in $ALL_CLUSTERS; do
    if aws ecs describe-clusters --clusters "$CN" \
        --query 'clusters[?status==`ACTIVE`]' --output text 2>/dev/null | grep -q .; then
        for SVC in $(aws ecs list-services --cluster "$CN" --query 'serviceArns' --output text 2>/dev/null); do
            SN=$(echo "$SVC" | awk -F/ '{print $NF}')
            aws ecs update-service --cluster "$CN" --service "$SN" --desired-count 0 > /dev/null 2>&1 || true
            aws ecs delete-service --cluster "$CN" --service "$SN" --force > /dev/null 2>&1 || true
            ok "Service deleted: $CN/$SN"
        done
    fi
done

# =============================================================================
# 2. DEREGISTER TASK DEFINITIONS (base + numbered families)
# =============================================================================

step "Task Definitions"
for FAM in "${PROJECT_NAME}-proxy-sql" "${PROJECT_NAME}-proxy-server" proxysql proxyserver-task query-logging-task dam-server-task postgresql-task; do
    # matches "proxysql", "proxysql-2", etc. via family-prefix
    for TD in $(aws ecs list-task-definitions --family-prefix "$FAM" --query 'taskDefinitionArns' --output text 2>/dev/null); do
        aws ecs deregister-task-definition --task-definition "$TD" > /dev/null 2>&1 || true
    done
done
ok "Task definitions deregistered"

# =============================================================================
# 3. DELETE ECS CLUSTERS
# =============================================================================

step "ECS Clusters"
for CN in $ALL_CLUSTERS; do
    aws ecs delete-cluster --cluster "$CN" > /dev/null 2>&1 || true
    ok "Cluster deleted: $CN"
done

# =============================================================================
# 4. DELETE SERVICE CONNECT NAMESPACES (base + numbered)
# =============================================================================

step "Service Connect Namespaces"
for NS_ID in $(aws servicediscovery list-namespaces \
    --query "Namespaces[?starts_with(Name, '${NAMESPACE_NAME}')].Id" --output text 2>/dev/null); do
    [[ -z "$NS_ID" || "$NS_ID" == "None" ]] && continue
    for SVC in $(aws servicediscovery list-services \
        --filters "Name=NAMESPACE_ID,Values=$NS_ID" --query 'Services[*].Id' --output text 2>/dev/null); do
        aws servicediscovery delete-service --id "$SVC" 2>/dev/null || true
    done
    aws servicediscovery delete-namespace --id "$NS_ID" 2>/dev/null || true
    ok "Namespace deleted: $NS_ID"
done

# =============================================================================
# 5. DELETE EFS (by Name tag)
# =============================================================================

step "EFS"
# Match base and numbered EFS (cdx-jit-db-efs, cdx-jit-db-efs-2, ...)
EFS_IDS=$(aws efs describe-file-systems \
    --query "FileSystems[?Tags[?Key=='Name'&&starts_with(Value, '${PROJECT_NAME}-efs')]].FileSystemId" \
    --output text 2>/dev/null)
for EFS_ID in $EFS_IDS; do
    [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]] && continue
    for MT in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query 'MountTargets[*].MountTargetId' --output text 2>/dev/null); do
        aws efs delete-mount-target --mount-target-id "$MT" 2>/dev/null || true
    done
done
if [[ -n "$EFS_IDS" ]]; then
    info "Waiting for mount targets to delete..."
    sleep 30
    for EFS_ID in $EFS_IDS; do
        [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]] && continue
        for AP in $(aws efs describe-access-points --file-system-id "$EFS_ID" \
            --query 'AccessPoints[*].AccessPointId' --output text 2>/dev/null); do
            aws efs delete-access-point --access-point-id "$AP" 2>/dev/null || true
        done
        aws efs delete-file-system --file-system-id "$EFS_ID" 2>/dev/null || true
        ok "EFS deleted: $EFS_ID"
    done
fi

# =============================================================================
# 6. DELETE SECRET + S3
# =============================================================================

step "Secrets Manager + S3"
aws secretsmanager delete-secret --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery > /dev/null 2>&1 || true
ok "Secret deleted: $SECRET_NAME"

# Bucket name: use state hint, else derive default pattern
if [[ -z "$BUCKET_NAME" ]]; then
    BUCKET_NAME="cdx-jit-db-logs-${ACCOUNT_ID}"
fi
aws s3 rb "s3://$BUCKET_NAME" --force > /dev/null 2>&1 || true
ok "S3 bucket removed (if existed): $BUCKET_NAME"

# =============================================================================
# 7. DELETE VPC PEERING (by tag)
# =============================================================================

step "VPC Peering"
for PCX in $(aws ec2 describe-vpc-peering-connections \
    --filters "Name=tag:Purpose,Values=db-jit,database-iam-jit" "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true
    ok "Peering deleted: $PCX"
done

# =============================================================================
# 8. DELETE IAM ROLE + CUSTOM POLICIES
# =============================================================================

step "IAM Role ($ROLE_NAME)"
if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    for P in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
        --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$P" 2>/dev/null || true
    done
    for P in $(aws iam list-role-policies --role-name "$ROLE_NAME" \
        --query 'PolicyNames' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$P" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
    ok "Role deleted: $ROLE_NAME"
fi

for POL in "${PROJECT_NAME}-SecretsAccess" "${PROJECT_NAME}-EFSAccess" "${PROJECT_NAME}-S3Access" "${PROJECT_NAME}-CloudWatchLogs" "cdx-ECSRDSAssumeRolePolicy"; do
    ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POL}"
    if aws iam get-policy --policy-arn "$ARN" > /dev/null 2>&1; then
        for V in $(aws iam list-policy-versions --policy-arn "$ARN" \
            --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
            aws iam delete-policy-version --policy-arn "$ARN" --version-id "$V" 2>/dev/null || true
        done
        aws iam delete-policy --policy-arn "$ARN" 2>/dev/null || true
    fi
done
ok "Custom IAM policies deleted"

# =============================================================================
# 9. DELETE VPC (new-vpc scope — discover by Name tag)
# =============================================================================

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
[[ "$VPC_ID" == "None" ]] && VPC_ID=""

if [[ -n "$VPC_ID" ]]; then
    step "VPC Resources ($VPC_ID)"
    for NAT in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
        --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do
        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" > /dev/null 2>&1 || true
    done
    info "Waiting for NAT gateway(s)..."
    sleep 40
    for EIP in $(aws ec2 describe-addresses --query "Addresses[?Domain=='vpc'].AllocationId" --output text 2>/dev/null); do
        aws ec2 release-address --allocation-id "$EIP" 2>/dev/null || true
    done
    for ENI in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null); do
        aws ec2 delete-network-interface --network-interface-id "$ENI" 2>/dev/null || true
    done
    for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
        aws ec2 delete-subnet --subnet-id "$SUB" 2>/dev/null || true
    done
    for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
        aws ec2 delete-security-group --group-id "$SG" 2>/dev/null || true
    done
    for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null); do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
    done
    for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null); do
        for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
            --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
            aws ec2 disassociate-route-table --association-id "$ASSOC" 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$RT" 2>/dev/null || true
    done
    aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    ok "VPC deleted: $VPC_ID"
fi

# =============================================================================
# 10. DELETE LOG GROUPS
# =============================================================================

step "CloudWatch Log Groups"
# Delete all log groups under /ecs/<project>/ (catches base + numbered suffixes)
for LG in $(aws logs describe-log-groups --log-group-name-prefix "/ecs/${PROJECT_NAME}" \
    --query 'logGroups[*].logGroupName' --output text 2>/dev/null); do
    aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true
done
ok "Log groups deleted"

# =============================================================================
# 11. REMOVE STATE FILE
# =============================================================================

if [[ -f "$_STATE" ]]; then
    rm -f "$_STATE"
    ok "State file removed"
fi

echo ""
ok "Cleanup complete."
warn "Cross-account DB resources (cross-account role, RDS SG rules, DB VPC"
warn "routes) in the database account must be cleaned up manually."
