#!/usr/bin/env bash
# =============================================================================
# AWS JIT EKS — Cleanup Script
# =============================================================================
# Tears down all resources created by the setup orchestrator.
# Reads outputs/config from the state file.
# Order: ECS service → task defs → ECS cluster (if we created it) → log group
#        → IAM role → peering → VPC (new-vpc only) → permission sets
#
# Called by: setup.sh --cleanup (STATE_FILE already set)
# =============================================================================

if [[ ! -f "$STATE_FILE" ]]; then
    error "No state file found at $STATE_FILE"
    return 1 2>/dev/null || exit 1
fi

get_output() {
    jq -r --arg key "$1" \
        '[.steps[] | select(.status=="complete") | .outputs // {} | to_entries[]] | .[] | select(.key==$key) | .value' \
        "$STATE_FILE" 2>/dev/null
}
get_cfg() {
    jq -r --arg key "$1" '.config[$key] // ""' "$STATE_FILE" 2>/dev/null
}

# =============================================================================
# READ STATE
# =============================================================================

SCOPE_MODE=$(jq -r '.scope_mode' "$STATE_FILE")
AWS_REGION=$(get_cfg "AWS_REGION")
JIT_ACCOUNT_ID=$(get_cfg "JIT_ACCOUNT_ID")
EKS_ACCOUNT_ID=$(get_cfg "EKS_ACCOUNT_ID")
EKS_REGION=$(get_cfg "EKS_REGION")
SSO_INSTANCE_ARN=$(get_cfg "SSO_INSTANCE_ARN")
ECS_CLUSTER_MODE=$(get_cfg "ECS_CLUSTER_MODE")

VPC_ID=$(get_output "VPC_ID")
ECS_CLUSTER_NAME=$(get_output "ECS_CLUSTER_NAME")
[[ -z "$ECS_CLUSTER_NAME" ]] && ECS_CLUSTER_NAME=$(get_cfg "ECS_CLUSTER_NAME")
BASTION_SG_ID=$(get_output "BASTION_SG_ID")
BASTION_SERVICE_NAME=$(get_output "BASTION_SERVICE_NAME")
BASTION_TASK_FAMILY=$(get_output "BASTION_TASK_FAMILY")
PEERING_CONNECTION_ID=$(get_output "PEERING_CONNECTION_ID")
NAT_GATEWAY_ID=$(get_output "NAT_GATEWAY_ID")

ROLE_NAME="cdx-jit-k8s-bastion-ECSRole"
LOG_GROUP="/ecs/cdx-jit-k8s/bastion"
SERVICE_NAME="${BASTION_SERVICE_NAME:-cdx-jit-k8s-bastion}"
TASK_FAMILY="${BASTION_TASK_FAMILY:-cdx-jit-k8s-bastion}"

export AWS_DEFAULT_REGION="$AWS_REGION"

info "Region: $AWS_REGION | Scope: $SCOPE_MODE"
info "Cluster: $ECS_CLUSTER_NAME | Bastion service: $SERVICE_NAME"

# =============================================================================
# ONBOARD-CLUSTER scope: only remove the peering it created (leave bastion)
# =============================================================================

if [[ "$SCOPE_MODE" == "onboard-cluster" ]]; then
    step "Onboard Peering"
    if [[ -n "$PEERING_CONNECTION_ID" && "$PEERING_CONNECTION_ID" != "null" ]]; then
        aws ec2 delete-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_CONNECTION_ID" > /dev/null 2>&1 || true
        ok "Peering deleted: $PEERING_CONNECTION_ID"
    fi
    ok "Onboard-cluster cleanup complete (bastion left intact)"
    rm -f "$STATE_FILE"
    ok "State file removed"
    return 0 2>/dev/null || exit 0
fi

# =============================================================================
# 1. DELETE BASTION ECS SERVICE
# =============================================================================

step "ECS Bastion Service"
if [[ -n "$ECS_CLUSTER_NAME" ]]; then
    if aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
        --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text 2>/dev/null | grep -q "$SERVICE_NAME"; then
        aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
            --desired-count 0 > /dev/null 2>&1 || true
        aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
            --force > /dev/null 2>&1 || true
        ok "Bastion service deleted: $SERVICE_NAME"
    else
        ok "No active bastion service found"
    fi
fi

# =============================================================================
# 2. DEREGISTER TASK DEFINITIONS
# =============================================================================

step "Task Definitions"
for TD_ARN in $(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" \
    --query 'taskDefinitionArns' --output text 2>/dev/null); do
    aws ecs deregister-task-definition --task-definition "$TD_ARN" > /dev/null 2>&1 || true
done
ok "Task definitions deregistered: $TASK_FAMILY"

# =============================================================================
# 3. DELETE ECS CLUSTER (only if this setup created it)
# =============================================================================

step "ECS Cluster"
if [[ "$ECS_CLUSTER_MODE" == "new" && -n "$ECS_CLUSTER_NAME" ]]; then
    # Only delete if no other active services remain
    REMAINING=$(aws ecs list-services --cluster "$ECS_CLUSTER_NAME" \
        --query 'length(serviceArns)' --output text 2>/dev/null || echo "0")
    if [[ "$REMAINING" == "0" ]]; then
        aws ecs delete-cluster --cluster "$ECS_CLUSTER_NAME" > /dev/null 2>&1 || true
        ok "Cluster deleted: $ECS_CLUSTER_NAME"
    else
        warn "Cluster $ECS_CLUSTER_NAME has $REMAINING other service(s) — leaving it in place"
    fi
else
    info "ECS cluster reused (mode: existing) — leaving it in place"
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
fi

# =============================================================================
# 6. DELETE VPC PEERING
# =============================================================================

step "VPC Peering"
if [[ -n "$PEERING_CONNECTION_ID" && "$PEERING_CONNECTION_ID" != "null" ]]; then
    aws ec2 delete-vpc-peering-connection \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" > /dev/null 2>&1 || true
    ok "Peering deleted: $PEERING_CONNECTION_ID"
fi

# =============================================================================
# 7. DELETE VPC RESOURCES (new-vpc scope only)
# =============================================================================

if [[ "$SCOPE_MODE" == "new-vpc" && -n "$VPC_ID" && "$VPC_ID" != "null" ]]; then
    step "VPC Resources"

    if [[ -n "$NAT_GATEWAY_ID" && "$NAT_GATEWAY_ID" != "null" ]]; then
        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GATEWAY_ID" > /dev/null 2>&1 || true
        info "Waiting for NAT gateway to delete..."
        sleep 40
    fi

    for EIP in $(aws ec2 describe-addresses --query "Addresses[?Domain=='vpc'].AllocationId" --output text 2>/dev/null); do
        aws ec2 release-address --allocation-id "$EIP" 2>/dev/null || true
    done

    # Delete any leftover ENIs (Fargate tasks)
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
else
    # existing-vpc: just delete the bastion SG we created
    if [[ -n "$BASTION_SG_ID" && "$BASTION_SG_ID" != "null" ]]; then
        aws ec2 delete-security-group --group-id "$BASTION_SG_ID" 2>/dev/null || true
        ok "Bastion security group deleted: $BASTION_SG_ID"
    fi
fi

# =============================================================================
# 8. DELETE SSO PERMISSION SETS
# =============================================================================

step "SSO Permission Sets"
if [[ -n "$SSO_INSTANCE_ARN" && "$SSO_INSTANCE_ARN" != "null" ]]; then
    PERMISSION_SETS=(
        "AmazonEKSAdminPolicy"
        "AmazonEKSClusterAdminPolicy"
        "AmazonEKSAdminViewPolicy"
        "AmazonEKSEditPolicy"
        "AmazonEKSViewPolicy"
    )
    # Only delete if the user confirms — permission sets may be shared
    if prompt_yes_no "Delete the 5 EKS SSO permission sets? (they may be used by other setups)" "n"; then
        for PS_NAME in "${PERMISSION_SETS[@]}"; do
            # Find ARN by name
            NEXT_TOKEN=""
            PS_ARN=""
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
                aws sso-admin delete-permission-set --instance-arn "$SSO_INSTANCE_ARN" \
                    --permission-set-arn "$PS_ARN" 2>/dev/null || true
                ok "Deleted permission set: $PS_NAME"
            fi
        done
    else
        info "Left permission sets in place"
    fi
fi

# =============================================================================
# 9. DELETE STATE FILE
# =============================================================================

step "State File"
rm -f "$STATE_FILE"
ok "State file removed"

echo ""
ok "Cleanup complete."
warn "Cross-account/cross-region resources (peering acceptance side, EKS SG rules)"
warn "in the EKS account must be cleaned up manually if applicable."
