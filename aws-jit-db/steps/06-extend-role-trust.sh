#!/usr/bin/env bash
# =============================================================================
# Step: Extend Role Trust Policy (DB Account)
# =============================================================================
# Run in the DATABASE account. Updates the trust policy of the cross-account
# role to allow assumption from the ECS task role in the JIT workload account.
#
# Required env vars:
#   AWS_REGION, JIT_ACCOUNT_ID
#
# Outputs:
#   OUTPUT:TRUST_UPDATED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION JIT_ACCOUNT_ID

# =============================================================================
# CONFIGURATION
# =============================================================================

ROLE_NAME="cdx-jit-db-cross-account-role"
PROJECT_NAME="cdx-jit-db"
ECS_ROLE_NAME="${PROJECT_NAME}-ECSRole"
# The ARN of the ECS task role in the JIT workload account
ECS_TASK_ROLE_ARN="arn:aws:iam::${JIT_ACCOUNT_ID}:role/${ECS_ROLE_NAME}"

info "DB Account: $(aws sts get-caller-identity --query Account --output text)"
info "JIT Account: $JIT_ACCOUNT_ID"
info "ECS Task Role: $ECS_TASK_ROLE_ARN"

# =============================================================================
# GET CURRENT TRUST POLICY
# =============================================================================

step "Update Trust Policy"

CURRENT_TRUST=$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)

if [[ -z "$CURRENT_TRUST" ]]; then
    error "Role $ROLE_NAME not found. Run step 05 first."; exit 1
fi

# Check if the ECS task role is already trusted
ALREADY_TRUSTED=$(echo "$CURRENT_TRUST" | jq -r \
    --arg arn "$ECS_TASK_ROLE_ARN" \
    '.Statement[] | select(.Principal.AWS != null) | 
     if (.Principal.AWS | type) == "array" then
         .Principal.AWS[] | select(. == $arn)
     else
         select(.Principal.AWS == $arn) | .Principal.AWS
     end' 2>/dev/null)

if [[ -n "$ALREADY_TRUSTED" ]]; then
    ok "Trust policy already includes: $ECS_TASK_ROLE_ARN"
else
    # Add the ECS task role to the trust policy
    NEW_TRUST=$(echo "$CURRENT_TRUST" | jq \
        --arg arn "$ECS_TASK_ROLE_ARN" \
        '.Statement += [{
            "Effect": "Allow",
            "Principal": {"AWS": $arn},
            "Action": "sts:AssumeRole"
        }]')

    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
        --policy-document "$NEW_TRUST"
    ok "Trust policy updated — added $ECS_TASK_ROLE_ARN"
fi

# =============================================================================
# VERIFY
# =============================================================================

info "Verifying trust policy..."
VERIFIED=$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument.Statement[*].Principal.AWS' --output text 2>/dev/null)
info "Trusted principals: $VERIFIED"

# =============================================================================
# OUTPUT
# =============================================================================

ok "Trust policy extension complete"
echo "OUTPUT:TRUST_UPDATED=true"
