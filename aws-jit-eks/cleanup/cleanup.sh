#!/usr/bin/env bash
# =============================================================================
# AWS JIT EKS — Cleanup Script (discovery-based, state file optional)
# =============================================================================
# Tears down JIT EKS resources by DISCOVERING them via well-known names and
# tags (purpose=cdx-jit-k8s). Works with or without a .state.json file — if
# state exists it's used only for hints (region, scope, cluster mode).
#
# Fixed resource names created by setup:
#   ECS service / task family : cdx-jit-k8s-bastion
#   IAM role                  : cdx-jit-k8s-bastion-ECSRole
#   Security group            : cdx-jit-k8s-hub-bastion-sg
#   Log group                 : /ecs/cdx-jit-k8s/bastion
#   Hub VPC (new-vpc)         : tag Name=cdx-jit-k8s-hub-vpc
#   Peering                   : tag Purpose=eks-jit
#
# Called by: setup.sh --cleanup
# =============================================================================

# ----- Optional hints from state file -----
_STATE="${STATE_FILE:-}"
get_cfg()    { [[ -f "$_STATE" ]] && jq -r --arg k "$1" '.config[$k] // ""' "$_STATE" 2>/dev/null || echo ""; }
get_out()    { [[ -f "$_STATE" ]] && jq -r --arg k "$1" '[.steps[]?|select(.status=="complete")|.outputs//{}|to_entries[]]|.[]|select(.key==$k)|.value' "$_STATE" 2>/dev/null || echo ""; }

# Region: state hint → env → current CLI config → default
AWS_REGION="$(get_cfg AWS_REGION)"
[[ -z "$AWS_REGION" ]] && AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
export AWS_DEFAULT_REGION="$AWS_REGION"

SCOPE_MODE="$(jq -r '.scope_mode // ""' "$_STATE" 2>/dev/null || echo "")"
ECS_CLUSTER_MODE="$(get_cfg ECS_CLUSTER_MODE)"

# Fixed names
SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-bastion-ECSRole"
LOG_GROUP="/ecs/cdx-jit-k8s/bastion"
SERVICE_NAME="cdx-jit-k8s-bastion"
TASK_FAMILY="cdx-jit-k8s-bastion"
VPC_NAME="cdx-jit-k8s-hub-vpc"

info "Region: $AWS_REGION | Scope hint: ${SCOPE_MODE:-<none>}"

# =============================================================================
# DISCOVER: bastion SG + its VPC + which cluster runs the bastion service
# =============================================================================

step "Discover Resources"

BASTION_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[[ "$BASTION_SG" == "None" ]] && BASTION_SG=""

BASTION_VPC=""
if [[ -n "$BASTION_SG" ]]; then
    BASTION_VPC=$(aws ec2 describe-security-groups --group-ids "$BASTION_SG" \
        --query 'SecurityGroups[0].VpcId' --output text 2>/dev/null)
fi

# Find which cluster the bastion service lives in (search all clusters)
BASTION_CLUSTER=""
for C in $(aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null); do
    CN=$(echo "$C" | awk -F/ '{print $NF}')
    FOUND=$(aws ecs describe-services --cluster "$CN" --services "$SERVICE_NAME" \
        --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text 2>/dev/null)
    if [[ -n "$FOUND" && "$FOUND" != "None" ]]; then
        BASTION_CLUSTER="$CN"
        break
    fi
done

info "Bastion SG: ${BASTION_SG:-<not found>} | VPC: ${BASTION_VPC:-<not found>}"
info "Bastion cluster: ${BASTION_CLUSTER:-<not found>}"

# =============================================================================
# ONBOARD-CLUSTER scope: only delete peering(s), leave bastion intact
# =============================================================================

if [[ "$SCOPE_MODE" == "onboard-cluster" ]]; then
    step "Onboard Peering"
    ONBOARD_PCX=$(get_out PEERING_CONNECTION_ID)
    if [[ -n "$ONBOARD_PCX" && "$ONBOARD_PCX" != "null" ]]; then
        aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$ONBOARD_PCX" 2>/dev/null || true
        ok "Peering deleted: $ONBOARD_PCX"
    else
        warn "No peering ID in state — delete the onboarded cluster's peering manually"
    fi
    [[ -f "$_STATE" ]] && rm -f "$_STATE" && ok "State file removed"
    ok "Onboard cleanup complete (bastion left intact)"
    return 0 2>/dev/null || exit 0
fi

# =============================================================================
# 1. DELETE BASTION ECS SERVICE
# =============================================================================

step "ECS Bastion Service"
if [[ -n "$BASTION_CLUSTER" ]]; then
    aws ecs update-service --cluster "$BASTION_CLUSTER" --service "$SERVICE_NAME" \
        --desired-count 0 > /dev/null 2>&1 || true
    aws ecs delete-service --cluster "$BASTION_CLUSTER" --service "$SERVICE_NAME" \
        --force > /dev/null 2>&1 || true
    ok "Bastion service deleted from $BASTION_CLUSTER"
else
    ok "No active bastion service found"
fi

# =============================================================================
# 2. DEREGISTER TASK DEFINITIONS
# =============================================================================

step "Task Definitions"
for TD in $(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" \
    --query 'taskDefinitionArns' --output text 2>/dev/null); do
    aws ecs deregister-task-definition --task-definition "$TD" > /dev/null 2>&1 || true
done
ok "Task definitions deregistered: $TASK_FAMILY"

# =============================================================================
# 3. DELETE ECS CLUSTER (only if WE created it — cdx-jit-k8s-cluster with no other services)
# =============================================================================

step "ECS Cluster"
# Only consider deleting a cluster that looks like ours (created by this setup).
# Never delete a reused jit-db/jit-vm cluster.
if [[ -n "$BASTION_CLUSTER" && "$BASTION_CLUSTER" == cdx-jit-k8s-* ]]; then
    REMAINING=$(aws ecs list-services --cluster "$BASTION_CLUSTER" \
        --query 'length(serviceArns)' --output text 2>/dev/null || echo "0")
    if [[ "$REMAINING" == "0" ]]; then
        aws ecs delete-cluster --cluster "$BASTION_CLUSTER" > /dev/null 2>&1 || true
        ok "Cluster deleted: $BASTION_CLUSTER"
    else
        warn "Cluster $BASTION_CLUSTER still has $REMAINING service(s) — leaving it"
    fi
else
    info "Bastion ran in a shared/reused cluster (${BASTION_CLUSTER:-unknown}) — leaving it"
fi

# =============================================================================
# 4. DELETE CLOUDWATCH LOG GROUP
# =============================================================================

step "CloudWatch Log Group"
aws logs delete-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
ok "Log group deleted: $LOG_GROUP"

# =============================================================================
# 5. DELETE IAM ROLE
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
else
    ok "Role not found (already deleted)"
fi

# =============================================================================
# 6. DELETE VPC PEERING (by tag Purpose=eks-jit)
# =============================================================================

step "VPC Peering"
for PCX in $(aws ec2 describe-vpc-peering-connections \
    --filters "Name=tag:Purpose,Values=eks-jit" "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true
    ok "Peering deleted: $PCX"
done

# =============================================================================
# 7. DELETE VPC (new-vpc scope) OR just the bastion SG (existing-vpc)
# =============================================================================

# Discover the hub VPC by its Name tag (created only in new-vpc scope)
HUB_VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
[[ "$HUB_VPC" == "None" ]] && HUB_VPC=""

if [[ -n "$HUB_VPC" ]]; then
    step "Hub VPC Resources ($HUB_VPC)"

    for NAT in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$HUB_VPC" "Name=state,Values=available,pending" \
        --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do
        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" > /dev/null 2>&1 || true
    done
    info "Waiting for NAT gateway(s) to delete..."
    sleep 40

    for EIP in $(aws ec2 describe-addresses --query "Addresses[?Domain=='vpc'].AllocationId" --output text 2>/dev/null); do
        aws ec2 release-address --allocation-id "$EIP" 2>/dev/null || true
    done

    for ENI in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$HUB_VPC" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null); do
        aws ec2 delete-network-interface --network-interface-id "$ENI" 2>/dev/null || true
    done

    for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$HUB_VPC" \
        --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
        aws ec2 delete-subnet --subnet-id "$SUB" 2>/dev/null || true
    done

    for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$HUB_VPC" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
        aws ec2 delete-security-group --group-id "$SG" 2>/dev/null || true
    done

    for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$HUB_VPC" \
        --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null); do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$HUB_VPC" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
    done

    for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$HUB_VPC" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null); do
        for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
            --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
            aws ec2 disassociate-route-table --association-id "$ASSOC" 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$RT" 2>/dev/null || true
    done

    aws ec2 delete-vpc --vpc-id "$HUB_VPC" 2>/dev/null || true
    ok "Hub VPC deleted: $HUB_VPC"
elif [[ -n "$BASTION_SG" ]]; then
    step "Bastion Security Group (existing VPC)"
    # ENIs may linger briefly after the service deletes; retry a couple times
    for _try in 1 2 3; do
        if aws ec2 delete-security-group --group-id "$BASTION_SG" 2>/dev/null; then
            ok "Bastion SG deleted: $BASTION_SG"
            break
        fi
        info "SG still in use (ENIs draining), retrying in 20s..."
        sleep 20
    done
fi

# =============================================================================
# 8. DELETE SSO PERMISSION SETS (prompted — may be shared)
# =============================================================================

step "SSO Permission Sets"
SSO_INSTANCE_ARN=$(aws sso-admin list-instances --query "Instances[0].InstanceArn" --output text 2>/dev/null || echo "")
if [[ -n "$SSO_INSTANCE_ARN" && "$SSO_INSTANCE_ARN" != "None" ]]; then
    if prompt_yes_no "Delete the 5 EKS SSO permission sets? (may be used by other setups)" "n"; then
        for PS_NAME in AmazonEKSAdminPolicy AmazonEKSClusterAdminPolicy AmazonEKSAdminViewPolicy AmazonEKSEditPolicy AmazonEKSViewPolicy; do
            NEXT_TOKEN=""; PS_ARN=""
            while true; do
                if [[ -n "$NEXT_TOKEN" ]]; then
                    RESP=$(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" --next-token "$NEXT_TOKEN" --output json 2>/dev/null)
                else
                    RESP=$(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" --output json 2>/dev/null)
                fi
                for arn in $(echo "$RESP" | jq -r '.PermissionSets[]? // empty'); do
                    nm=$(aws sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" \
                        --permission-set-arn "$arn" --query 'PermissionSet.Name' --output text 2>/dev/null)
                    if [[ "$nm" == "$PS_NAME" ]]; then PS_ARN="$arn"; break; fi
                done
                [[ -n "$PS_ARN" ]] && break
                NEXT_TOKEN=$(echo "$RESP" | jq -r '.NextToken // empty')
                [[ -z "$NEXT_TOKEN" ]] && break
            done
            if [[ -n "$PS_ARN" ]]; then
                aws sso-admin delete-permission-set --instance-arn "$SSO_INSTANCE_ARN" --permission-set-arn "$PS_ARN" 2>/dev/null || true
                ok "Deleted permission set: $PS_NAME"
            fi
        done
    else
        info "Left permission sets in place"
    fi
fi

# =============================================================================
# 9. REMOVE STATE FILE (if present)
# =============================================================================

if [[ -f "$_STATE" ]]; then
    rm -f "$_STATE"
    ok "State file removed"
fi

echo ""
ok "Cleanup complete."
echo ""
warn "The following are NOT removed automatically and must be cleaned up manually:"
warn "  • SSO permission sets in the Management account (IAM Identity Center),"
warn "    created from these EKS access policies: AmazonEKSAdminPolicy,"
warn "    AmazonEKSClusterAdminPolicy, AmazonEKSAdminViewPolicy, AmazonEKSEditPolicy,"
warn "    AmazonEKSViewPolicy. Remove their account assignments first, then delete"
warn "    any that are unused."
warn "  • EKS-side resources (peering acceptance, EKS SG rules, routes) in the EKS"
warn "    account/region if it is a different account."
