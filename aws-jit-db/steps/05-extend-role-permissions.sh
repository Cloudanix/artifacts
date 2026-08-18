#!/usr/bin/env bash
# =============================================================================
# Step: Extend Role Permissions (DB Account)
# =============================================================================
# Run in the DATABASE account. Creates or updates the cross-account IAM role
# with RDS permissions so that the JIT ECS tasks can manage database access
# (create/revoke temporary DB credentials).
#
# Required env vars:
#   AWS_REGION
#
# Outputs:
#   OUTPUT:ROLE_UPDATED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION

# =============================================================================
# CONFIGURATION
# =============================================================================

ROLE_NAME="cdx-jit-db-cross-account-role"
POLICY_NAME="cdx-jit-db-rds-permissions"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

info "Account: $ACCOUNT_ID | Region: $AWS_REGION"
info "Role: $ROLE_NAME"

# =============================================================================
# CREATE OR UPDATE ROLE
# =============================================================================

step "Cross-Account Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""

if [[ -z "$ROLE_ARN" ]]; then
    # Create the role with a placeholder trust policy (updated in step 06)
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{
            "Version":"2012-10-17",
            "Statement":[{
                "Effect":"Allow",
                "Principal":{"AWS":"arn:aws:iam::'$ACCOUNT_ID':root"},
                "Action":"sts:AssumeRole"
            }]
        }' \
        --tags "Key=Purpose,Value=db-jit" "Key=created_by,Value=cloudanix" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "Role created: $ROLE_NAME ($ROLE_ARN)"
else
    ok "Role exists: $ROLE_NAME ($ROLE_ARN)"
fi

# =============================================================================
# ATTACH RDS PERMISSIONS
# =============================================================================

step "RDS Permissions Policy"

cat > /tmp/rds-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "RDSDescribe",
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBInstances",
                "rds:DescribeDBClusters",
                "rds:ListTagsForResource"
            ],
            "Resource": "*"
        },
        {
            "Sid": "RDSConnect",
            "Effect": "Allow",
            "Action": [
                "rds-db:connect"
            ],
            "Resource": "*"
        },
        {
            "Sid": "SecretsManagerDBCreds",
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:CreateSecret",
                "secretsmanager:UpdateSecret",
                "secretsmanager:DeleteSecret",
                "secretsmanager:TagResource"
            ],
            "Resource": "*",
            "Condition": {
                "StringLike": {
                    "secretsmanager:ResourceTag/created_by": "cloudanix"
                }
            }
        }
    ]
}
EOF

# Check if policy already exists (idempotent put)
aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document file:///tmp/rds-policy.json
ok "Policy attached: $POLICY_NAME"

# =============================================================================
# OUTPUT
# =============================================================================

ok "Role permissions extended successfully"
echo "OUTPUT:ROLE_UPDATED=true"
