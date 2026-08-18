#!/usr/bin/env bash
# =============================================================================
# Step: Update ECS Task Role Assume-Role Policy
# =============================================================================
# Run in the JIT WORKLOAD account. Adds an inline policy to the ECS task role
# allowing it to assume the cross-account role in the DB account.
#
# Required env vars:
#   AWS_REGION, DB_ACCOUNT_ID
#
# Outputs:
#   OUTPUT:ASSUME_ROLE_UPDATED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION DB_ACCOUNT_ID

# =============================================================================
# CONFIGURATION
# =============================================================================

PROJECT_NAME="cdx-jit-db"
ECS_ROLE_NAME="${PROJECT_NAME}-ECSRole"
POLICY_NAME="${PROJECT_NAME}-assume-db-role"
CROSS_ACCOUNT_ROLE_ARN="arn:aws:iam::${DB_ACCOUNT_ID}:role/cdx-jit-db-cross-account-role"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
info "JIT Account: $ACCOUNT_ID | DB Account: $DB_ACCOUNT_ID"
info "ECS Role: $ECS_ROLE_NAME"
info "Target: $CROSS_ACCOUNT_ROLE_ARN"

# =============================================================================
# VALIDATE ECS ROLE EXISTS
# =============================================================================

step "Validate ECS Role"
ROLE_ARN=$(aws iam get-role --role-name "$ECS_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    error "ECS Role $ECS_ROLE_NAME not found. Run step 02 first."; exit 1
fi
ok "ECS Role: $ECS_ROLE_NAME ($ROLE_ARN)"

# =============================================================================
# CHECK EXISTING POLICY
# =============================================================================

step "Assume-Role Policy"

# Check if policy already grants access to this DB account role
EXISTING_POLICY=$(aws iam get-role-policy --role-name "$ECS_ROLE_NAME" \
    --policy-name "$POLICY_NAME" --query 'PolicyDocument' --output json 2>/dev/null) || EXISTING_POLICY=""

if [[ -n "$EXISTING_POLICY" ]]; then
    ALREADY_HAS=$(echo "$EXISTING_POLICY" | jq -r \
        --arg arn "$CROSS_ACCOUNT_ROLE_ARN" \
        '.Statement[].Resource | if type == "array" then .[] else . end | select(. == $arn)' 2>/dev/null)
    if [[ -n "$ALREADY_HAS" ]]; then
        ok "Policy already includes: $CROSS_ACCOUNT_ROLE_ARN"
        echo "OUTPUT:ASSUME_ROLE_UPDATED=true"
        exit 0
    fi

    # Add to existing resource list
    NEW_POLICY=$(echo "$EXISTING_POLICY" | jq \
        --arg arn "$CROSS_ACCOUNT_ROLE_ARN" \
        '.Statement[0].Resource = (
            if (.Statement[0].Resource | type) == "array" then
                .Statement[0].Resource + [$arn]
            else
                [.Statement[0].Resource, $arn]
            end
        )')
else
    # Create new policy
    NEW_POLICY=$(jq -n --arg arn "$CROSS_ACCOUNT_ROLE_ARN" '{
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "AssumeDBAccountRole",
            "Effect": "Allow",
            "Action": "sts:AssumeRole",
            "Resource": $arn
        }]
    }')
fi

# =============================================================================
# APPLY POLICY
# =============================================================================

aws iam put-role-policy --role-name "$ECS_ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "$NEW_POLICY"
ok "Policy updated: $POLICY_NAME → $CROSS_ACCOUNT_ROLE_ARN"

# =============================================================================
# OUTPUT
# =============================================================================

ok "Assume-role policy update complete"
echo "OUTPUT:ASSUME_ROLE_UPDATED=true"
