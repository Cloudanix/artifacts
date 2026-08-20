#!/usr/bin/env bash
# =============================================================================
# AWS JIT Database — Cleanup Script
# =============================================================================
# Tears down all resources created by the setup orchestrator.
# Reads outputs from the state file to identify what to delete.
# Runs in reverse order: services → cluster → EFS → secrets → S3 → IAM → VPC
#
# Called by: setup.sh --cleanup (state file and config are already loaded)
# =============================================================================

# State file is already set by the caller (setup.sh)
if [[ ! -f "$STATE_FILE" ]]; then
    error "No state file found at $STATE_FILE"
    return 1
fi

# Helper: get output value from state
get_output() {
    jq -r --arg key "$1" \
        '[.steps[] | select(.status=="complete") | .outputs // {} | to_entries[]] | .[] | select(.key==$key) | .value' \
        "$STATE_FILE" 2>/dev/null
}

# Helper: get config value
get_cfg() {
    jq -r --arg key "$1" '.config[$key] // ""' "$STATE_FILE" 2>/dev/null
}

# =============================================================================
# READ STATE
# =============================================================================

AWS_REGION=$(get_cfg "AWS_REGION")
PROJECT_NAME=$(get_cfg "PROJECT_NAME")
ECS_CLUSTER_NAME=$(get_cfg "ECS_CLUSTER_NAME")
BUCKET_NAME=$(get_cfg "BUCKET_NAME")
SECRET_NAME=$(get_cfg "SECRET_NAME")
JIT_ACCOUNT_ID=$(get_cfg "JIT_ACCOUNT_ID")
DB_ACCOUNT_ID=$(get_cfg "DB_ACCOUNT_ID")
SSO_INSTANCE_ARN=$(get_cfg "SSO_INSTANCE_ARN")
PERMISSION_SET_NAME=$(get_cfg "PERMISSION_SET_NAME")

VPC_ID=$(get_output "VPC_ID")
ECS_SG_ID=$(get_output "ECS_SG_ID")
EFS_ID=$(get_output "EFS_ID")
NAT_GATEWAY_ID=$(get_output "NAT_GATEWAY_ID")
PEERING_CONNECTION_ID=$(get_output "PEERING_CONNECTION_ID")
PERMISSION_SET_ARN=$(get_output "PERMISSION_SET_ARN")
SECRET_ARN=$(get_output "SECRET_ARN")
NAMESPACE_ID=$(get_output "NAMESPACE_ID")

ROLE_NAME="${PROJECT_NAME}-ECSRole"
CROSS_ACCOUNT_ROLE="cdx-jit-db-cross-account-role"

export AWS_DEFAULT_REGION="$AWS_REGION"

info "Region: $AWS_REGION | Project: $PROJECT_NAME"
info "VPC: $VPC_ID | Cluster: $ECS_CLUSTER_NAME"

# =============================================================================
# 1. DELETE ECS SERVICES
# =============================================================================

step "ECS Services"
if [[ -n "$ECS_CLUSTER_NAME" ]]; then
    SERVICES=$(aws ecs list-services --cluster "$ECS_CLUSTER_NAME" \
        --query 'serviceArns' --output text 2>/dev/null || echo "")
    if [[ -n "$SERVICES" && "$SERVICES" != "None" ]]; then
        for SVC_ARN in $SERVICES; do
            SVC_NAME=$(echo "$SVC_ARN" | awk -F'/' '{print $NF}')
            info "Stopping service: $SVC_NAME"
            aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SVC_NAME" \
                --desired-count 0 > /dev/null 2>&1 || true
            aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$SVC_NAME" \
                --force > /dev/null 2>&1 || true
        done
        ok "Services deleted"
    else
        ok "No services found"
    fi
fi

# =============================================================================
# 2. DELETE ECS CLUSTER
# =============================================================================

step "ECS Cluster"
if [[ -n "$ECS_CLUSTER_NAME" ]]; then
    aws ecs delete-cluster --cluster "$ECS_CLUSTER_NAME" > /dev/null 2>&1 || true
    ok "Cluster deleted: $ECS_CLUSTER_NAME"
fi

# =============================================================================
# 3. DELETE SERVICE CONNECT NAMESPACE
# =============================================================================

step "Service Connect Namespace"
if [[ -n "$NAMESPACE_ID" && "$NAMESPACE_ID" != "null" ]]; then
    aws servicediscovery delete-namespace --id "$NAMESPACE_ID" > /dev/null 2>&1 || true
    ok "Namespace deleted: $NAMESPACE_ID"
else
    # Try to find it by name
    NS_ID=$(aws servicediscovery list-namespaces \
        --query "Namespaces[?Name=='proxysql-proxyserver'].Id | [0]" --output text 2>/dev/null)
    if [[ -n "$NS_ID" && "$NS_ID" != "None" ]]; then
        aws servicediscovery delete-namespace --id "$NS_ID" > /dev/null 2>&1 || true
        ok "Namespace deleted: $NS_ID"
    fi
fi

# =============================================================================
# 4. DELETE EFS
# =============================================================================

step "EFS"
if [[ -n "$EFS_ID" && "$EFS_ID" != "null" ]]; then
    # Delete mount targets first
    MT_IDS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query 'MountTargets[*].MountTargetId' --output text 2>/dev/null || echo "")
    for MT in $MT_IDS; do
        aws efs delete-mount-target --mount-target-id "$MT" 2>/dev/null || true
    done
    if [[ -n "$MT_IDS" ]]; then
        info "Waiting for mount targets to delete..."
        sleep 30
    fi
    # Delete access points
    AP_IDS=$(aws efs describe-access-points --file-system-id "$EFS_ID" \
        --query 'AccessPoints[*].AccessPointId' --output text 2>/dev/null || echo "")
    for AP in $AP_IDS; do
        aws efs delete-access-point --access-point-id "$AP" 2>/dev/null || true
    done
    # Delete filesystem
    aws efs delete-file-system --file-system-id "$EFS_ID" 2>/dev/null || true
    ok "EFS deleted: $EFS_ID"
fi

# =============================================================================
# 5. DELETE SECRETS MANAGER SECRET
# =============================================================================

step "Secrets Manager"
if [[ -n "$SECRET_NAME" ]]; then
    aws secretsmanager delete-secret --secret-id "$SECRET_NAME" \
        --force-delete-without-recovery > /dev/null 2>&1 || true
    ok "Secret deleted: $SECRET_NAME"
fi

# =============================================================================
# 6. DELETE S3 BUCKET
# =============================================================================

step "S3 Bucket"
if [[ -n "$BUCKET_NAME" ]]; then
    aws s3 rb "s3://$BUCKET_NAME" --force > /dev/null 2>&1 || true
    ok "S3 deleted: $BUCKET_NAME"
fi

# =============================================================================
# 7. DELETE VPC PEERING
# =============================================================================

step "VPC Peering"
if [[ -n "$PEERING_CONNECTION_ID" && "$PEERING_CONNECTION_ID" != "null" ]]; then
    aws ec2 delete-vpc-peering-connection \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" > /dev/null 2>&1 || true
    ok "Peering deleted: $PEERING_CONNECTION_ID"
fi

# =============================================================================
# 8. DELETE IAM ROLE & POLICIES (JIT Account)
# =============================================================================

step "IAM Role ($ROLE_NAME)"
if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    # Detach all policies
    POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
        --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || echo "")
    for P in $POLICIES; do
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$P" 2>/dev/null || true
    done
    # Delete inline policies
    INLINE=$(aws iam list-role-policies --role-name "$ROLE_NAME" \
        --query 'PolicyNames' --output text 2>/dev/null || echo "")
    for P in $INLINE; do
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$P" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
    ok "Role deleted: $ROLE_NAME"
fi

# Delete custom policies created by the setup
for POLICY_NAME in "${PROJECT_NAME}-SecretsAccess" "${PROJECT_NAME}-EFSAccess" "${PROJECT_NAME}-S3Access" "${PROJECT_NAME}-CloudWatchLogs" "cdx-ECSRDSAssumeRolePolicy"; do
    POLICY_ARN="arn:aws:iam::${JIT_ACCOUNT_ID}:policy/${POLICY_NAME}"
    if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
        # Delete all non-default versions
        VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
            --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || echo "")
        for V in $VERSIONS; do
            aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$V" 2>/dev/null || true
        done
        aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
    fi
done
ok "Custom IAM policies deleted"

# =============================================================================
# 9. DELETE CROSS-ACCOUNT ROLE (DB Account) — only if same account
# =============================================================================

step "Cross-Account Role"
if [[ "$DB_ACCOUNT_ID" == "$JIT_ACCOUNT_ID" || -z "$DB_ACCOUNT_ID" ]]; then
    if aws iam get-role --role-name "$CROSS_ACCOUNT_ROLE" > /dev/null 2>&1; then
        POLICIES=$(aws iam list-attached-role-policies --role-name "$CROSS_ACCOUNT_ROLE" \
            --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || echo "")
        for P in $POLICIES; do
            aws iam detach-role-policy --role-name "$CROSS_ACCOUNT_ROLE" --policy-arn "$P" 2>/dev/null || true
        done
        INLINE=$(aws iam list-role-policies --role-name "$CROSS_ACCOUNT_ROLE" \
            --query 'PolicyNames' --output text 2>/dev/null || echo "")
        for P in $INLINE; do
            aws iam delete-role-policy --role-name "$CROSS_ACCOUNT_ROLE" --policy-name "$P" 2>/dev/null || true
        done
        aws iam delete-role --role-name "$CROSS_ACCOUNT_ROLE" 2>/dev/null || true
        ok "Cross-account role deleted: $CROSS_ACCOUNT_ROLE"
    fi
    # Delete RDS policies
    for POLICY_NAME in "cdx-RDSConnectPolicy" "cdx-RDSAuthTokenGenerationPolicy"; do
        POLICY_ARN="arn:aws:iam::${JIT_ACCOUNT_ID}:policy/${POLICY_NAME}"
        if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
            aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
        fi
    done
else
    warn "Cross-account role in DB account ($DB_ACCOUNT_ID) must be deleted manually"
fi

# =============================================================================
# 10. DELETE VPC RESOURCES (only for new-vpc scope)
# =============================================================================

SCOPE_MODE=$(jq -r '.scope_mode' "$STATE_FILE")
if [[ "$SCOPE_MODE" == "new-vpc" && -n "$VPC_ID" && "$VPC_ID" != "null" ]]; then
    step "VPC Resources"

    # Delete NAT Gateway
    if [[ -n "$NAT_GATEWAY_ID" && "$NAT_GATEWAY_ID" != "null" ]]; then
        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GATEWAY_ID" > /dev/null 2>&1 || true
        info "Waiting for NAT gateway to delete..."
        sleep 30
    fi

    # Release EIPs associated with this VPC
    EIPS=$(aws ec2 describe-addresses --query "Addresses[?Domain=='vpc'].AllocationId" --output text 2>/dev/null || echo "")
    for EIP in $EIPS; do
        aws ec2 release-address --allocation-id "$EIP" 2>/dev/null || true
    done

    # Delete subnets
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' --output text 2>/dev/null || echo "")
    for SUB in $SUBNETS; do
        aws ec2 delete-subnet --subnet-id "$SUB" 2>/dev/null || true
    done

    # Delete security groups (except default)
    SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || echo "")
    for SG in $SGS; do
        aws ec2 delete-security-group --group-id "$SG" 2>/dev/null || true
    done

    # Detach and delete internet gateway
    IGWS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || echo "")
    for IGW in $IGWS; do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
    done

    # Delete route tables (except main)
    RTS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null || echo "")
    for RT in $RTS; do
        # Disassociate first
        ASSOCS=$(aws ec2 describe-route-tables --route-table-ids "$RT" \
            --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null || echo "")
        for ASSOC in $ASSOCS; do
            aws ec2 disassociate-route-table --association-id "$ASSOC" 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$RT" 2>/dev/null || true
    done

    # Delete VPC
    aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    ok "VPC deleted: $VPC_ID"
else
    # For existing-vpc scope, just delete the security group
    if [[ -n "$ECS_SG_ID" && "$ECS_SG_ID" != "null" ]]; then
        aws ec2 delete-security-group --group-id "$ECS_SG_ID" 2>/dev/null || true
        ok "Security group deleted: $ECS_SG_ID"
    fi
fi

# =============================================================================
# 11. DELETE CLOUDWATCH LOG GROUPS
# =============================================================================

step "CloudWatch Log Groups"
for LG in "/ecs/${PROJECT_NAME}/proxyserver" "/ecs/${PROJECT_NAME}/proxysql" "/ecs/${PROJECT_NAME}/query-logging" "/ecs/${PROJECT_NAME}/dam-server" "/ecs/${PROJECT_NAME}/postgresql"; do
    aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true
done
ok "Log groups deleted"

# =============================================================================
# 12. DELETE STATE FILE
# =============================================================================

step "State File"
rm -f "$STATE_FILE"
ok "State file removed"

echo ""
ok "Cleanup complete. All resources have been removed."
