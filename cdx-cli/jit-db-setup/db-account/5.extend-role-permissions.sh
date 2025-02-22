#!/bin/bash
set -e
set -u

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $ACCOUNT_ID"
ROLE_NAME=$(prompt_with_default "ROLE NAME" "cdx-role_cross_accnt")

# Variables
ROLES=(
    "$ROLE_NAME"
)

# Create RDS Connect policy
log "Creating RDS Connect policy..."
RDS_CONNECT_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds-db:connect"
            ],
            "Resource": [
                "arn:aws:rds-db:*:$ACCOUNT_ID:*:*/*"
            ]
        }
    ]
}
EOF
)

# Create RDS Authentication Token Generation policy
log "Creating RDS Auth Token Generation policy..."
RDS_AUTH_TOKEN_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:GetAuthenticationToken",
                "rds:DescribeDBClusters",
                "rds:DescribeDBInstances"
            ],
            "Resource": [
                "arn:aws:rds-db:*:$ACCOUNT_ID:*:*/*"
            ]
        }
    ]
}
EOF
)

# Create the policies in IAM
RDS_CONNECT_POLICY_ARN=$(aws iam create-policy \
    --policy-name cdx-RDSConnectPolicy \
    --policy-document "$RDS_CONNECT_POLICY" \
    --description "Policy for RDS IAM authentication connection" \
    --query 'Policy.Arn' \
    --output text)

RDS_AUTH_TOKEN_POLICY_ARN=$(aws iam create-policy \
    --policy-name cdx-RDSAuthTokenGenerationPolicy \
    --policy-document "$RDS_AUTH_TOKEN_POLICY" \
    --description "Policy for generating RDS auth tokens" \
    --query 'Policy.Arn' \
    --output text)

# Attach policies to roles
for ROLE_NAME in "${ROLES[@]}"; do
    log "Attaching RDS policies to role: $ROLE_NAME"
    
    # Attach RDS Connect policy
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$RDS_CONNECT_POLICY_ARN"
    
    # Attach RDS Auth Token Generation policy
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$RDS_AUTH_TOKEN_POLICY_ARN"
    
    log "Successfully attached RDS policies to $ROLE_NAME"
done

log "All RDS policies have been created and attached"

# Verify the attached policies
for ROLE_NAME in "${ROLES[@]}"; do
    log "Verifying policies for role: $ROLE_NAME"
    aws iam list-attached-role-policies --role-name "$ROLE_NAME"
done