#!/usr/bin/env bash
# =============================================================================
# Step: Create SSO Permission Sets for EKS Access
# =============================================================================
# Run in the MANAGEMENT account. Creates SSO permission sets that map to EKS
# access policies. These are empty permission sets (no AWS policies) used as
# identifiers for EKS access entry creation.
#
# Required env vars:
#   AWS_REGION, SSO_INSTANCE_ARN, JIT_ACCOUNT_ID, ECS_CLUSTER_NAME,
#   BASTION_SERVICE_NAME
#
# Outputs:
#   OUTPUT:PERMISSION_SET_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION SSO_INSTANCE_ARN JIT_ACCOUNT_ID ECS_CLUSTER_NAME BASTION_SERVICE_NAME

# =============================================================================
# CONFIGURATION
# =============================================================================

SESSION_DURATION="PT1H"

info "SSO Instance: $SSO_INSTANCE_ARN"
info "JIT Account: $JIT_ACCOUNT_ID"
info "ECS Cluster: $ECS_CLUSTER_NAME | Bastion service: $BASTION_SERVICE_NAME"
info "EKS Cluster: $EKS_CLUSTER_NAME"

PERMISSION_SETS=(
    "AmazonEKSAdminPolicy"
    "AmazonEKSClusterAdminPolicy"
    "AmazonEKSAdminViewPolicy"
    "AmazonEKSEditPolicy"
    "AmazonEKSViewPolicy"
)

# =============================================================================
# HELPER: Find permission set by name
# =============================================================================

find_permission_set_arn() {
    local name=$1
    local next_token=""
    while true; do
        local args=(--instance-arn "$SSO_INSTANCE_ARN" --region "$AWS_REGION" --output json)
        if [[ -n "$next_token" ]]; then
            args+=(--next-token "$next_token")
        fi
        local response
        response=$(aws sso-admin list-permission-sets "${args[@]}" 2>/dev/null)

        local arns
        arns=$(echo "$response" | jq -r '.PermissionSets[]? // empty')
        for arn in $arns; do
            local ps_name
            ps_name=$(aws sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" \
                --permission-set-arn "$arn" --query "PermissionSet.Name" --output text \
                --region "$AWS_REGION" 2>/dev/null)
            if [[ "$ps_name" == "$name" ]]; then
                echo "$arn"
                return 0
            fi
        done

        next_token=$(echo "$response" | jq -r '.NextToken // empty')
        if [[ -z "$next_token" || "$next_token" == "null" ]]; then break; fi
    done
    echo ""
}

# =============================================================================
# CREATE PERMISSION SETS (idempotent)
# =============================================================================

step "Create Permission Sets"

FIRST_PS_ARN=""
for PS_NAME in "${PERMISSION_SETS[@]}"; do
    info "Checking: $PS_NAME"

    EXISTING_ARN=$(find_permission_set_arn "$PS_NAME")

    if [[ -n "$EXISTING_ARN" ]]; then
        ok "  Already exists: $PS_NAME ($EXISTING_ARN)"
        if [[ -z "$FIRST_PS_ARN" ]]; then FIRST_PS_ARN="$EXISTING_ARN"; fi
    else
        PS_ARN=$(aws sso-admin create-permission-set \
            --instance-arn "$SSO_INSTANCE_ARN" \
            --name "$PS_NAME" \
            --description "EKS JIT access policy - $PS_NAME" \
            --session-duration "$SESSION_DURATION" \
            --query "PermissionSet.PermissionSetArn" --output text \
            --region "$AWS_REGION")
        ok "  Created: $PS_NAME ($PS_ARN)"
        if [[ -z "$FIRST_PS_ARN" ]]; then FIRST_PS_ARN="$PS_ARN"; fi
    fi
done

# =============================================================================
# ADD SSM INLINE POLICY (for bastion access)
# =============================================================================

step "SSM Inline Policy (first permission set)"

# Add ECS Exec policy to the admin permission set for bastion access.
# Access to the Fargate bastion is via `aws ecs execute-command`, which opens
# an SSM session channel into the running task.
ADMIN_PS_ARN=$(find_permission_set_arn "AmazonEKSClusterAdminPolicy")
if [[ -n "$ADMIN_PS_ARN" ]]; then
    cat > /tmp/eks-bastion-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ECSExecBastion",
            "Effect": "Allow",
            "Action": [
                "ecs:ExecuteCommand",
                "ecs:DescribeTasks",
                "ecs:ListTasks",
                "ecs:DescribeServices"
            ],
            "Resource": [
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:cluster/${ECS_CLUSTER_NAME}",
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:task/${ECS_CLUSTER_NAME}/*",
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:service/${ECS_CLUSTER_NAME}/*"
            ]
        },
        {
            "Sid": "SSMExecChannel",
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession",
                "ssm:DescribeSessions",
                "ssm:TerminateSession"
            ],
            "Resource": [
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:task/${ECS_CLUSTER_NAME}/*",
                "arn:aws:ssm:${AWS_REGION}::document/AWS-StartPortForwardingSessionToRemoteHost"
            ]
        }
    ]
}
EOF

    aws sso-admin put-inline-policy-to-permission-set \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --permission-set-arn "$ADMIN_PS_ARN" \
        --inline-policy file:///tmp/eks-bastion-policy.json \
        --region "$AWS_REGION" 2>/dev/null || true
    ok "ECS Exec bastion policy attached to AmazonEKSClusterAdminPolicy"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Permission sets created"
info "Assign these to users/groups for EKS JIT access"
echo "OUTPUT:PERMISSION_SET_ARN=${FIRST_PS_ARN}"
