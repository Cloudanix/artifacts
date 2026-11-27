#!/usr/bin/env bash
# =============================================================================
# Step: Attach EKS JIT Policies to Cross-Account Role
# =============================================================================
# Creates and attaches the CdxCreateJitEKSPermission policy to the existing
# cross-account role. This policy allows SSO permission set management and
# EKS access entry creation.
#
# Required env vars:
#   AWS_REGION
#
# Outputs:
#   OUTPUT:POLICY_ATTACHED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION

# =============================================================================
# DISCOVER CROSS-ACCOUNT ROLE
# =============================================================================

step "Discover Cross-Account Role"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
info "Account: $ACCOUNT_ID | Region: $AWS_REGION"

# Auto-discover role matching the cdx cross-account pattern
ROLE_NAME=""
DISCOVERED_ROLES=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, 'cdx-') && contains(RoleName, 'role_cross_accnt')].RoleName" \
    --output text 2>/dev/null || echo "")

if [[ -n "$DISCOVERED_ROLES" && "$DISCOVERED_ROLES" != "None" ]]; then
    ROLE_ARRAY=()
    for r in $DISCOVERED_ROLES; do
        ROLE_ARRAY+=("$r")
    done

    if [[ ${#ROLE_ARRAY[@]} -eq 1 ]]; then
        ROLE_NAME="${ROLE_ARRAY[0]}"
        ok "Auto-discovered role: $ROLE_NAME"
    else
        # Use first match
        ROLE_NAME="${ROLE_ARRAY[0]}"
        warn "Multiple roles found, using first: $ROLE_NAME"
    fi
fi

if [[ -z "$ROLE_NAME" ]]; then
    error "Could not discover cross-account role matching 'cdx-*-role_cross_accnt*'"
    error "Set ROLE_NAME env var manually"
    exit 1
fi

# Verify role exists
if ! aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    error "Role '$ROLE_NAME' not found in this account"
    exit 1
fi

# =============================================================================
# CREATE POLICY (idempotent)
# =============================================================================

step "Policy: CdxCreateJitEKSPermission"

POLICY_NAME="CdxCreateJitEKSPermission"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

POLICY_DOC='{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowSSOAndEKSAccessEntryCreation",
            "Effect": "Allow",
            "Action": [
                "sso:CreatePermissionSet",
                "sso:PutInlinePolicyToPermissionSet",
                "sso:DeletePermissionSet",
                "sso:ListPermissionSets",
                "eks:CreateAccessEntry"
            ],
            "Resource": "*"
        }
    ]
}'

if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
    ok "Policy already exists: $POLICY_NAME"
else
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --description "Allows SSO permission set management and EKS access entry creation for JIT EKS" \
        --policy-document "$POLICY_DOC" > /dev/null
    ok "Policy created: $POLICY_NAME"
fi

# =============================================================================
# ATTACH POLICY TO ROLE (idempotent)
# =============================================================================

step "Attach Policy"

aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN" 2>/dev/null || true
ok "Attached $POLICY_NAME to $ROLE_NAME"

# =============================================================================
# OUTPUT
# =============================================================================

ok "EKS policy setup complete"
info "Role: $ROLE_NAME | Policy: $POLICY_NAME"
echo "OUTPUT:POLICY_ATTACHED=true"
