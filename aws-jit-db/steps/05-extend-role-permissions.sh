#!/usr/bin/env bash
# =============================================================================
# Step: Extend Role Permissions (DB Account)
# =============================================================================
# Run in the DATABASE account. Creates or updates the cross-account IAM role
# with RDS permissions so that the JIT ECS tasks can manage database access.
#
# Creates two managed policies:
#   - cdx-RDSConnectPolicy: rds-db:connect
#   - cdx-RDSAuthTokenGenerationPolicy: rds:GetAuthenticationToken, Describe
#
# And creates the cross-account role that the JIT ECS task will assume.
#
# Required env vars:
#   AWS_REGION
#
# Outputs:
#   OUTPUT:ROLE_UPDATED=true
#   OUTPUT:CROSS_ACCOUNT_ROLE_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
export CDX_PURPOSE=jit_db

require_env AWS_REGION

# =============================================================================
# CONFIGURATION
# =============================================================================

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
info "Account: $ACCOUNT_ID | Region: $AWS_REGION"

# =============================================================================
# DISCOVER EXISTING CROSS-ACCOUNT ROLE(S)
# =============================================================================
# The Cloudanix cross-account role(s) already exist in the DB account (created
# during account onboarding), named like:
#   cdx-<region>-<account>-role_cross_accnt<hash>
# We do NOT create a role here — we find the existing one(s) and attach the RDS
# policies to each. An explicit CROSS_ACCOUNT_ROLE_NAME (from config/env)
# overrides discovery.

step "Discover Cross-Account Role(s)"
CROSS_ACCOUNT_ROLES=()

if [[ -n "${CROSS_ACCOUNT_ROLE_NAME:-}" ]]; then
    if aws iam get-role --role-name "$CROSS_ACCOUNT_ROLE_NAME" > /dev/null 2>&1; then
        CROSS_ACCOUNT_ROLES=("$CROSS_ACCOUNT_ROLE_NAME")
        ok "Using provided role: $CROSS_ACCOUNT_ROLE_NAME"
    else
        error "Provided CROSS_ACCOUNT_ROLE_NAME '$CROSS_ACCOUNT_ROLE_NAME' not found."
        exit 1
    fi
else
    # Discover by the Cloudanix cross-account naming pattern.
    while IFS= read -r rn; do
        [[ -n "$rn" ]] && CROSS_ACCOUNT_ROLES+=("$rn")
    done < <(aws iam list-roles \
        --query "Roles[?contains(RoleName, 'role_cross_accnt')].RoleName" \
        --output text 2>/dev/null | tr '\t' '\n')

    # Backward-compat: legacy fixed-name role from earlier builds.
    if [[ ${#CROSS_ACCOUNT_ROLES[@]} -eq 0 ]]; then
        if aws iam get-role --role-name "cdx-jit-db-cross-account-role" > /dev/null 2>&1; then
            CROSS_ACCOUNT_ROLES=("cdx-jit-db-cross-account-role")
        fi
    fi
fi

if [[ ${#CROSS_ACCOUNT_ROLES[@]} -eq 0 ]]; then
    error "No Cloudanix cross-account role found in account $ACCOUNT_ID."
    error "Expected a role named like 'cdx-<region>-<account>-role_cross_accnt<hash>'."
    error "Ensure the account is onboarded in Cloudanix first, or set"
    error "CROSS_ACCOUNT_ROLE_NAME to the exact role name."
    exit 1
fi
ok "Cross-account role(s): ${CROSS_ACCOUNT_ROLES[*]}"

# =============================================================================
# RDS CONNECT POLICY
# =============================================================================

step "RDS Connect Policy"
RDS_CONNECT_POLICY_NAME="cdx-RDSConnectPolicy"
RDS_CONNECT_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${RDS_CONNECT_POLICY_NAME}"

if aws iam get-policy --policy-arn "$RDS_CONNECT_POLICY_ARN" > /dev/null 2>&1; then
    ok "Policy exists: $RDS_CONNECT_POLICY_NAME"
else
    RDS_CONNECT_POLICY_ARN=$(aws iam create-policy \
        --policy-name "$RDS_CONNECT_POLICY_NAME" \
        --description "Policy for RDS IAM authentication connection" \
        --policy-document '{
            "Version":"2012-10-17",
            "Statement":[{
                "Effect":"Allow",
                "Action":["rds-db:connect"],
                "Resource":["arn:aws:rds-db:*:'$ACCOUNT_ID':*:*/*"]
            }]
        }' \
        --query 'Policy.Arn' --output text)
    ok "Policy created: $RDS_CONNECT_POLICY_NAME"
fi
for _r in "${CROSS_ACCOUNT_ROLES[@]}"; do
    aws iam attach-role-policy --role-name "$_r" --policy-arn "$RDS_CONNECT_POLICY_ARN" 2>/dev/null || true
done

# =============================================================================
# RDS AUTH TOKEN GENERATION POLICY
# =============================================================================

step "RDS Auth Token Policy"
RDS_AUTH_POLICY_NAME="cdx-RDSAuthTokenGenerationPolicy"
RDS_AUTH_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${RDS_AUTH_POLICY_NAME}"

if aws iam get-policy --policy-arn "$RDS_AUTH_POLICY_ARN" > /dev/null 2>&1; then
    ok "Policy exists: $RDS_AUTH_POLICY_NAME"
else
    RDS_AUTH_POLICY_ARN=$(aws iam create-policy \
        --policy-name "$RDS_AUTH_POLICY_NAME" \
        --description "Policy for generating RDS auth tokens" \
        --policy-document '{
            "Version":"2012-10-17",
            "Statement":[{
                "Effect":"Allow",
                "Action":[
                    "rds:GetAuthenticationToken",
                    "rds:DescribeDBClusters",
                    "rds:DescribeDBInstances"
                ],
                "Resource":["arn:aws:rds-db:*:'$ACCOUNT_ID':*:*/*"]
            }]
        }' \
        --query 'Policy.Arn' --output text)
    ok "Policy created: $RDS_AUTH_POLICY_NAME"
fi
for _r in "${CROSS_ACCOUNT_ROLES[@]}"; do
    aws iam attach-role-policy --role-name "$_r" --policy-arn "$RDS_AUTH_POLICY_ARN" 2>/dev/null || true
done

# =============================================================================
# VERIFY
# =============================================================================

for _r in "${CROSS_ACCOUNT_ROLES[@]}"; do
    info "Attached policies on $_r:"
    aws iam list-attached-role-policies --role-name "$_r" \
        --query 'AttachedPolicies[*].PolicyName' --output text
done

# =============================================================================
# OUTPUT
# =============================================================================
# Emit the discovered role name(s) so downstream steps (trust + assume-role)
# operate on the same role(s). Space-separated when more than one.

CROSS_ACCOUNT_ROLE_NAMES="${CROSS_ACCOUNT_ROLES[*]}"
ok "Role permissions extended successfully"
echo "OUTPUT:ROLE_UPDATED=true"
echo "OUTPUT:CROSS_ACCOUNT_ROLE_NAMES=${CROSS_ACCOUNT_ROLE_NAMES}"
