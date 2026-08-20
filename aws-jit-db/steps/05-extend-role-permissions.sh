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

require_env AWS_REGION

# =============================================================================
# CONFIGURATION
# =============================================================================

ROLE_NAME="cdx-jit-db-cross-account-role"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

info "Account: $ACCOUNT_ID | Region: $AWS_REGION"
info "Role: $ROLE_NAME"

# =============================================================================
# CREATE OR UPDATE ROLE
# =============================================================================

step "Cross-Account Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""

if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{
            "Version":"2012-10-17",
            "Statement":[{
                "Effect":"Allow",
                "Principal":{"AWS":"arn:aws:iam::'$ACCOUNT_ID':root"},
                "Action":"sts:AssumeRole"
            }]
        }' \
        --tags "Key=Purpose,Value=database-iam-jit" "Key=created_by,Value=cloudanix" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "Role created: $ROLE_NAME ($ROLE_ARN)"
else
    ok "Role exists: $ROLE_NAME ($ROLE_ARN)"
fi

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
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$RDS_CONNECT_POLICY_ARN" 2>/dev/null || true

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
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$RDS_AUTH_POLICY_ARN" 2>/dev/null || true

# =============================================================================
# VERIFY
# =============================================================================

info "Attached policies:"
aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[*].PolicyName' --output text

# =============================================================================
# OUTPUT
# =============================================================================

ok "Role permissions extended successfully"
echo "OUTPUT:ROLE_UPDATED=true"
echo "OUTPUT:CROSS_ACCOUNT_ROLE_ARN=${ROLE_ARN}"
