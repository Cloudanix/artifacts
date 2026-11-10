#!/usr/bin/env bash
# =============================================================================
# Step: Create SSO Permission Set (Management Account)
# =============================================================================
# Run in the MANAGEMENT account. Creates an SSO permission set that grants
# users the ability to use SSM sessions and ECS Exec against the JIT DB
# cluster for port-forwarding access.
#
# If the permission set already exists, merges new statements into the
# existing inline policy (preserving entries for other clusters/accounts).
#
# Required env vars:
#   AWS_REGION, SSO_INSTANCE_ARN, PERMISSION_SET_NAME, JIT_ACCOUNT_ID,
#   ECS_CLUSTER_NAME
#
# Outputs:
#   OUTPUT:PERMISSION_SET_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION SSO_INSTANCE_ARN JIT_ACCOUNT_ID

# =============================================================================
# CONFIGURATION
# =============================================================================

SESSION_DURATION="PT8H"

# Defaults for fields not collected in every scope (e.g. same-account).
PERMISSION_SET_NAME="${PERMISSION_SET_NAME:-cdx-EcsSsmAccess}"
PROJECT_NAME="${PROJECT_NAME:-cdx-jit-db}"
# same-account derives the cluster as <project>-cluster-<setup#>; otherwise
# ECS_CLUSTER_NAME is provided directly.
if [[ -z "${ECS_CLUSTER_NAME:-}" ]]; then
    if [[ -n "${SETUP_NUMBER:-}" ]]; then
        ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster-${SETUP_NUMBER}"
    else
        ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
    fi
fi

# Generate unique Sid suffixes from account + cluster (alphanumeric only)
SID_ACCOUNT=$(echo "$JIT_ACCOUNT_ID" | tr -cd '[:alnum:]')
SID_CLUSTER=$(echo "$ECS_CLUSTER_NAME" | tr -cd '[:alnum:]')

info "SSO Instance: $SSO_INSTANCE_ARN"
info "Permission Set: $PERMISSION_SET_NAME"
info "JIT Account: $JIT_ACCOUNT_ID | Cluster: $ECS_CLUSTER_NAME"

# =============================================================================
# BUILD NEW STATEMENTS FOR THIS CLUSTER
# =============================================================================

NEW_STATEMENTS=$(jq -n \
    --arg region "$AWS_REGION" \
    --arg account "$JIT_ACCOUNT_ID" \
    --arg cluster "$ECS_CLUSTER_NAME" \
    --arg sid_ssm "SSMSessionAndCommandPolicy${SID_ACCOUNT}${SID_CLUSTER}" \
    --arg sid_ecs "ECSDescribeAndListTasksServices${SID_ACCOUNT}${SID_CLUSTER}" \
    '[
        {
            "Sid": $sid_ssm,
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession",
                "ssm:DescribeSessions",
                "ssm:TerminateSession",
                "ssm:SendCommand"
            ],
            "Resource": [
                "arn:aws:ecs:\($region):\($account):cluster/\($cluster)",
                "arn:aws:ecs:\($region):\($account):task/\($cluster)/*",
                "arn:aws:ec2:\($region):\($account):instance/*",
                "arn:aws:ssm:*:*:document/*",
                "arn:aws:ssm:*:*:session/*"
            ]
        },
        {
            "Sid": $sid_ecs,
            "Effect": "Allow",
            "Action": [
                "ecs:DescribeTasks",
                "ecs:ListTasks",
                "ecs:DescribeServices",
                "ecs:ListServices"
            ],
            "Resource": [
                "arn:aws:ecs:\($region):\($account):cluster/\($cluster)",
                "arn:aws:ecs:\($region):\($account):task/\($cluster)/*",
                "arn:aws:ecs:\($region):\($account):service/\($cluster)/*",
                "arn:aws:ecs:\($region):\($account):container-instance/\($cluster)/*"
            ]
        }
    ]')

# =============================================================================
# FIND OR CREATE PERMISSION SET
# =============================================================================

step "Permission Set"

find_permission_set_arn() {
    local next_token=""
    while true; do
        local response
        if [[ -z "$next_token" ]]; then
            response=$(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" \
                --region "$AWS_REGION" --output json 2>/dev/null)
        else
            response=$(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" \
                --next-token "$next_token" --region "$AWS_REGION" --output json 2>/dev/null)
        fi

        local ps_arns
        ps_arns=$(echo "$response" | jq -r '.PermissionSets[]' 2>/dev/null)
        for arn in $ps_arns; do
            local name
            name=$(aws sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" \
                --permission-set-arn "$arn" --query 'PermissionSet.Name' --output text \
                --region "$AWS_REGION" 2>/dev/null)
            if [[ "$name" == "$PERMISSION_SET_NAME" ]]; then
                echo "$arn"
                return 0
            fi
        done

        next_token=$(echo "$response" | jq -r '.NextToken // empty' 2>/dev/null)
        if [[ -z "$next_token" ]]; then break; fi
    done
    return 1
}

PERMISSION_SET_ARN=$(find_permission_set_arn 2>/dev/null || true)

if [[ -n "$PERMISSION_SET_ARN" ]]; then
    ok "Permission set exists: $PERMISSION_SET_NAME ($PERMISSION_SET_ARN)"
else
    PERMISSION_SET_ARN=$(aws sso-admin create-permission-set \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --name "$PERMISSION_SET_NAME" \
        --description "Custom permission set for ECS and SSM access" \
        --session-duration "$SESSION_DURATION" \
        --query 'PermissionSet.PermissionSetArn' --output text \
        --region "$AWS_REGION")
    ok "Permission set created: $PERMISSION_SET_NAME ($PERMISSION_SET_ARN)"
fi

# =============================================================================
# MERGE INLINE POLICY
# =============================================================================

step "Inline Policy"

# Get existing inline policy (if any)
EXISTING_POLICY=$(aws sso-admin get-inline-policy-for-permission-set \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --query 'InlinePolicy' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

if [[ -z "$EXISTING_POLICY" || "$EXISTING_POLICY" == "None" || "$EXISTING_POLICY" == "" ]]; then
    # No existing policy — create fresh from new statements
    MERGED_POLICY=$(echo "$NEW_STATEMENTS" | jq '{Version: "2012-10-17", Statement: .}')
else
    # Merge: keep existing statements whose Sid is NOT in the new set, then add new ones
    NEW_SIDS=$(echo "$NEW_STATEMENTS" | jq '[.[].Sid]')
    MERGED_POLICY=$(echo "$EXISTING_POLICY" | jq --argjson new_stmts "$NEW_STATEMENTS" --argjson new_sids "$NEW_SIDS" '
        .Statement = ([.Statement[] | select(.Sid as $s | $new_sids | index($s) | not)] + $new_stmts)
    ')
fi

# Write and apply
echo "$MERGED_POLICY" > /tmp/ps-policy.json
aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --inline-policy file:///tmp/ps-policy.json \
    --region "$AWS_REGION"
rm -f /tmp/ps-policy.json
ok "Inline policy attached (merged with existing)"

# =============================================================================
# OUTPUT
# =============================================================================

ok "Permission set setup complete"
info "Assign this permission set to users/groups for the JIT account ($JIT_ACCOUNT_ID)"
echo "OUTPUT:PERMISSION_SET_ARN=${PERMISSION_SET_ARN}"
