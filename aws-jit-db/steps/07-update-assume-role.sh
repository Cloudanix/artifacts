#!/usr/bin/env bash
# =============================================================================
# Step: Update ECS Task Role Assume-Role Policy
# =============================================================================
# Run in the JIT WORKLOAD account. Creates or updates the managed policy
# (cdx-ECSRDSAssumeRolePolicy) that allows the ECS task role to assume
# the cross-account role in the DB account.
#
# If the policy already exists (from a previous DB onboarding), appends the
# new role ARN to the Resource list. If it doesn't exist, creates it.
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
POLICY_NAME="cdx-ECSRDSAssumeRolePolicy"
CROSS_ACCOUNT_ROLE_NAME="cdx-jit-db-cross-account-role"
CROSS_ACCOUNT_ROLE_ARN="arn:aws:iam::${DB_ACCOUNT_ID}:role/${CROSS_ACCOUNT_ROLE_NAME}"

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
# CREATE OR UPDATE MANAGED POLICY
# =============================================================================

step "Assume-Role Policy"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
    # Policy exists — get current version and check if role ARN is already there
    DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
        --query 'Policy.DefaultVersionId' --output text)
    CURRENT_POLICY=$(aws iam get-policy-version --policy-arn "$POLICY_ARN" \
        --version-id "$DEFAULT_VERSION" --query 'PolicyVersion.Document' --output json)

    # Check if ARN already in Resource list
    ALREADY_HAS=$(echo "$CURRENT_POLICY" | jq -r \
        --arg arn "$CROSS_ACCOUNT_ROLE_ARN" \
        '.Statement[0].Resource | if type == "array" then .[] else . end | select(. == $arn)' 2>/dev/null)

    if [[ -n "$ALREADY_HAS" ]]; then
        ok "Policy already includes: $CROSS_ACCOUNT_ROLE_ARN"
        echo "OUTPUT:ASSUME_ROLE_UPDATED=true"
        exit 0
    fi

    # Add the new role ARN to the Resource array
    UPDATED_POLICY=$(echo "$CURRENT_POLICY" | jq \
        --arg arn "$CROSS_ACCOUNT_ROLE_ARN" \
        'if (.Statement[0].Resource | type) == "array" then
            .Statement[0].Resource += [$arn]
        else
            .Statement[0].Resource = [.Statement[0].Resource, $arn]
        end')

    # Delete oldest policy version if at limit (max 5 versions)
    VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'length(Versions)' --output text)
    if [[ "$VERSION_COUNT" -ge 5 ]]; then
        OLDEST=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
            --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate) | [0].VersionId' --output text)
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi

    # Create new version
    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
        --policy-document "$UPDATED_POLICY" --set-as-default > /dev/null
    ok "Policy updated: added $CROSS_ACCOUNT_ROLE_ARN"
else
    # Policy doesn't exist — create it
    NEW_POLICY=$(jq -n --arg arn "$CROSS_ACCOUNT_ROLE_ARN" '{
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "AssumeDBAccountRole",
            "Effect": "Allow",
            "Action": "sts:AssumeRole",
            "Resource": [$arn]
        }]
    }')

    POLICY_ARN=$(aws iam create-policy --policy-name "$POLICY_NAME" \
        --description "Allows ECS task role to assume cross-account DB roles" \
        --policy-document "$NEW_POLICY" \
        --query 'Policy.Arn' --output text)
    ok "Policy created: $POLICY_NAME"

    # Attach to ECS role
    aws iam attach-role-policy --role-name "$ECS_ROLE_NAME" --policy-arn "$POLICY_ARN"
    ok "Attached to $ECS_ROLE_NAME"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Assume-role policy update complete"
echo "OUTPUT:ASSUME_ROLE_UPDATED=true"
