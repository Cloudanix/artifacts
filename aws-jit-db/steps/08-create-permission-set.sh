#!/usr/bin/env bash
# =============================================================================
# Step: Create SSO Permission Set (Management Account)
# =============================================================================
# Run in the MANAGEMENT account. Creates an SSO permission set that grants
# users the ability to use SSM sessions and ECS Exec against the JIT DB
# cluster for port-forwarding access.
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

require_env AWS_REGION SSO_INSTANCE_ARN PERMISSION_SET_NAME JIT_ACCOUNT_ID ECS_CLUSTER_NAME

# =============================================================================
# CONFIGURATION
# =============================================================================

SESSION_DURATION="PT8H"

info "SSO Instance: $SSO_INSTANCE_ARN"
info "Permission Set: $PERMISSION_SET_NAME"
info "JIT Account: $JIT_ACCOUNT_ID | Cluster: $ECS_CLUSTER_NAME"

# =============================================================================
# CHECK EXISTING PERMISSION SET
# =============================================================================

step "Permission Set"

# List all permission sets and find by name
PERMISSION_SET_ARN=""
NEXT_TOKEN=""
while true; do
    if [[ -z "$NEXT_TOKEN" ]]; then
        RESPONSE=$(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" \
            --region "$AWS_REGION" --output json 2>/dev/null)
    else
        RESPONSE=$(aws sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" \
            --next-token "$NEXT_TOKEN" --region "$AWS_REGION" --output json 2>/dev/null)
    fi

    PS_ARNS=$(echo "$RESPONSE" | jq -r '.PermissionSets[]' 2>/dev/null)
    for PS_ARN in $PS_ARNS; do
        PS_NAME=$(aws sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" \
            --permission-set-arn "$PS_ARN" --query 'PermissionSet.Name' --output text \
            --region "$AWS_REGION" 2>/dev/null)
        if [[ "$PS_NAME" == "$PERMISSION_SET_NAME" ]]; then
            PERMISSION_SET_ARN="$PS_ARN"
            break 2
        fi
    done

    NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.NextToken // empty' 2>/dev/null)
    if [[ -z "$NEXT_TOKEN" ]]; then break; fi
done

if [[ -n "$PERMISSION_SET_ARN" ]]; then
    ok "Permission set exists: $PERMISSION_SET_NAME ($PERMISSION_SET_ARN)"
else
    # Create new permission set
    PERMISSION_SET_ARN=$(aws sso-admin create-permission-set \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --name "$PERMISSION_SET_NAME" \
        --description "JIT DB access via ECS SSM port-forwarding" \
        --session-duration "$SESSION_DURATION" \
        --query 'PermissionSet.PermissionSetArn' --output text \
        --region "$AWS_REGION")
    ok "Permission set created: $PERMISSION_SET_NAME ($PERMISSION_SET_ARN)"
fi

# =============================================================================
# INLINE POLICY
# =============================================================================

step "Inline Policy"

cat > /tmp/ps-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SSMSession",
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession",
                "ssm:DescribeSessions",
                "ssm:TerminateSession"
            ],
            "Resource": [
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:cluster/${ECS_CLUSTER_NAME}",
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:task/${ECS_CLUSTER_NAME}/*",
                "arn:aws:ssm:${AWS_REGION}::document/AWS-StartPortForwardingSession"
            ]
        },
        {
            "Sid": "ECSAccess",
            "Effect": "Allow",
            "Action": [
                "ecs:DescribeTasks",
                "ecs:ListTasks",
                "ecs:DescribeServices",
                "ecs:ListServices",
                "ecs:ExecuteCommand"
            ],
            "Resource": [
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:cluster/${ECS_CLUSTER_NAME}",
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:task/${ECS_CLUSTER_NAME}/*",
                "arn:aws:ecs:${AWS_REGION}:${JIT_ACCOUNT_ID}:service/${ECS_CLUSTER_NAME}/*"
            ]
        }
    ]
}
EOF

aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --inline-policy file:///tmp/ps-policy.json \
    --region "$AWS_REGION"
ok "Inline policy attached"

# =============================================================================
# OUTPUT
# =============================================================================

ok "Permission set setup complete"
info "Assign this permission set to users/groups for the JIT account ($JIT_ACCOUNT_ID)"
echo "OUTPUT:PERMISSION_SET_ARN=${PERMISSION_SET_ARN}"
