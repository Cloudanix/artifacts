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

require_env AWS_REGION

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# In same-account scope, DB is in the JIT account — default DB_ACCOUNT_ID to current.
DB_ACCOUNT_ID="${DB_ACCOUNT_ID:-$ACCOUNT_ID}"

# =============================================================================
# CONFIGURATION
# =============================================================================

PROJECT_NAME="${PROJECT_NAME:-cdx-jit-db}"
ECS_ROLE_NAME="${PROJECT_NAME}-ECSRole"
POLICY_NAME="cdx-ECSRDSAssumeRolePolicy"

info "JIT Account: $ACCOUNT_ID | DB Account: $DB_ACCOUNT_ID"
info "ECS Role: $ECS_ROLE_NAME"

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

# The ECS task must be able to assume the Cloudanix cross-account role(s) in any
# onboarded DB account. Since those roles are named dynamically
# (cdx-<region>-<account>-role_cross_accnt<hash>) and new accounts are onboarded
# over time, the assume-role policy uses a wildcard Resource ("*") rather than a
# fixed list of ARNs. Trust is still enforced on the DB side (each cross-account
# role's trust policy only allows THIS ECS task role), so the wildcard here does
# not grant broad access on its own.
DESIRED_POLICY=$(jq -n '{
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AssumeDBAccountRole",
        "Effect": "Allow",
        "Action": "sts:AssumeRole",
        "Resource": "*"
    }]
}')

if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
    DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
        --query 'Policy.DefaultVersionId' --output text)
    CURRENT_POLICY=$(aws iam get-policy-version --policy-arn "$POLICY_ARN" \
        --version-id "$DEFAULT_VERSION" --query 'PolicyVersion.Document' --output json)

    if [[ "$(echo "$CURRENT_POLICY" | jq -S .)" == "$(echo "$DESIRED_POLICY" | jq -S .)" ]]; then
        ok "Assume-role policy already correct (Resource: *)"
        echo "OUTPUT:ASSUME_ROLE_UPDATED=true"
        exit 0
    fi

    # Delete oldest non-default version if at the 5-version limit.
    VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'length(Versions)' --output text)
    if [[ "$VERSION_COUNT" -ge 5 ]]; then
        OLDEST=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
            --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate) | [0].VersionId' --output text)
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi

    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
        --policy-document "$DESIRED_POLICY" --set-as-default > /dev/null
    ok "Assume-role policy updated (Resource: *)"
else
    POLICY_ARN=$(aws iam create-policy --policy-name "$POLICY_NAME" \
        --description "Allows ECS task role to assume Cloudanix cross-account DB roles" \
        --policy-document "$DESIRED_POLICY" \
        --query 'Policy.Arn' --output text)
    ok "Policy created: $POLICY_NAME (Resource: *)"

    aws iam attach-role-policy --role-name "$ECS_ROLE_NAME" --policy-arn "$POLICY_ARN"
    ok "Attached to $ECS_ROLE_NAME"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Assume-role policy update complete"
echo "OUTPUT:ASSUME_ROLE_UPDATED=true"
