#!/usr/bin/env bash
# =============================================================================
# AWS JIT VM (SSH Proxy) — Cleanup Script (discovery-based, state optional)
# =============================================================================
# Tears down JIT VM resources by DISCOVERING them via well-known names and
# tags. Works with or without .state.json — state is used only for hints
# (region, project name, S3 bucket).
#
# Fixed names (PROJECT_NAME defaults to cdx-jit-vm):
#   ECS cluster        : <project>-cluster
#   Services           : jit-vm-proxy-sshpiper/-vmproxyserver/-vmcommandlogging
#   Task def families  : <project>-sshpiper/-vmproxyserver/-vmcommandlogging
#   IAM role           : <project>-ECSRole (inline: <project>-task-policy)
#   EFS                : tag Name=<project>-efs
#   Namespace          : <project>-local
#   VPC (new-vpc)      : tag Name=<project>-vpc
#   Secrets            : <project>-secret, <project>-ssh-keys
#   S3 (recordings)    : state hint or cdx-jit-vm-recordings-<account>
#   Log group          : /ecs/<project>
#   Peering            : tag purpose=jit_vm (and legacy Purpose=vm-jit)
#
# NOTE: onboard-* scopes create no infrastructure in the JIT account beyond
# peering/route/SG edits; running cleanup removes the discoverable JIT-side
# resources. VM-account SG rules added by onboard steps must be removed
# manually (they are plain ingress rules on customer security groups).
#
# Called by: setup.sh --cleanup
# =============================================================================

_STATE="${STATE_FILE:-}"
get_cfg() { [[ -f "$_STATE" ]] && jq -r --arg k "$1" '.config[$k] // ""' "$_STATE" 2>/dev/null || echo ""; }

AWS_REGION="$(get_cfg AWS_REGION)"
[[ -z "$AWS_REGION" ]] && AWS_REGION="$(aws configure get region 2>/dev/null || echo us-east-1)"
export AWS_DEFAULT_REGION="$AWS_REGION"

PROJECT_NAME="$(get_cfg PROJECT_NAME)"; [[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="cdx-jit-vm"
SCOPE_MODE="$(jq -r '.scope_mode // ""' "$_STATE" 2>/dev/null || echo "")"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_BUCKET_NAME="$(get_cfg S3_BUCKET_NAME)"

CLUSTER_NAME="${PROJECT_NAME}-cluster"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
NAMESPACE_NAME="${PROJECT_NAME}-local"
PERMISSION_SET_NAME="$(get_cfg PERMISSION_SET_NAME)"; [[ -z "$PERMISSION_SET_NAME" ]] && PERMISSION_SET_NAME="cdx-EcsVmSsmAccess"

info "Region: $AWS_REGION | Project: $PROJECT_NAME | Account: $ACCOUNT_ID"
info "Scope hint: ${SCOPE_MODE:-<none>}"

# =============================================================================
# DISCOVER ALL SETUPS: base cluster + numbered
# =============================================================================

ALL_CLUSTERS=$(aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null \
    | tr '\t' '\n' | awk -F/ '{print $NF}' | grep -E "^${CLUSTER_NAME}(-[0-9]+)?$" || echo "")
[[ -z "$ALL_CLUSTERS" ]] && ALL_CLUSTERS="$CLUSTER_NAME"
info "Clusters to clean: $(echo $ALL_CLUSTERS | tr '\n' ' ')"

# =============================================================================
# 1. DELETE ECS SERVICES
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
# 2. DEREGISTER TASK DEFINITIONS
# =============================================================================

step "Task Definitions"
for FAM in "${PROJECT_NAME}-sshpiper" "${PROJECT_NAME}-vmproxyserver" "${PROJECT_NAME}-vmcommandlogging"; do
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
# 5. DELETE EFS (by Name tag, base + numbered)
# =============================================================================

step "EFS"
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
# 6. DELETE SECRETS + S3
# =============================================================================

step "Secrets Manager + S3"
for SEC in "${PROJECT_NAME}-secret" "${PROJECT_NAME}-ssh-keys"; do
    aws secretsmanager delete-secret --secret-id "$SEC" \
        --force-delete-without-recovery > /dev/null 2>&1 || true
    ok "Secret deleted: $SEC"
done

if [[ -z "$S3_BUCKET_NAME" ]]; then
    S3_BUCKET_NAME="cdx-jit-vm-recordings-${ACCOUNT_ID}"
fi
aws s3 rb "s3://$S3_BUCKET_NAME" --force > /dev/null 2>&1 || true
ok "S3 bucket removed (if existed): $S3_BUCKET_NAME"

# =============================================================================
# 7. DELETE VPC PEERING (by tag)
# =============================================================================

step "VPC Peering"
for PCX in $(aws ec2 describe-vpc-peering-connections \
    --filters "Name=tag:purpose,Values=jit_vm" "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true
    ok "Peering deleted: $PCX"
done
# Legacy tag (Purpose=vm-jit) from earlier builds
for PCX in $(aws ec2 describe-vpc-peering-connections \
    --filters "Name=tag:Purpose,Values=vm-jit" "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true
    ok "Peering deleted (legacy tag): $PCX"
done

# =============================================================================
# 8. DELETE IAM ROLE + INLINE POLICY
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

# =============================================================================
# 9. DELETE VPC (new-vpc scope — discover by Name tag)
# =============================================================================

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
[[ "$VPC_ID" == "None" ]] && VPC_ID=""

if [[ -n "$VPC_ID" ]]; then
    step "VPC Resources ($VPC_ID)"
    # VPC endpoints first (they hold ENIs)
    for VPCE in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null); do
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE" > /dev/null 2>&1 || true
    done
    for NAT in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
        --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do
        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" > /dev/null 2>&1 || true
    done
    info "Waiting for NAT gateway(s) / endpoints..."
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
echo ""
warn "The following are NOT removed automatically and must be cleaned up manually:"
warn "  • SSO permission set '${PERMISSION_SET_NAME}' in the Management account"
warn "    (IAM Identity Center) — it may be assigned to users/groups. Remove its"
warn "    account assignments first, then delete the permission set if unused."
warn "  • SG ingress rules added to your VM security groups by onboard steps."
