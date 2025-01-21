#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Variables
JIT_DB_ACCOUNT_ID="$1"
JIT_DB_TASK_ROLE_ARN="arn:aws:iam::${JIT_DB_ACCOUNT_ID}:role/ECSTaskRole"
EXTERNAL_ID="$2"

# List of roles to update
ROLES=(
    "$3"
)

for ROLE_NAME in "${ROLES[@]}"; do
    log "Updating trust relationship for role: $ROLE_NAME"
    
    # Get current trust policy
    CURRENT_POLICY=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json)
    
    # Create new trust policy by adding the ECS task role
    NEW_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "sid1",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::774118602354:root"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "$EXTERNAL_ID"
                }
            }
        },
        {
            "Sid": "sid2",
            "Effect": "Allow",
            "Principal": {
                "AWS": "$JIT_DB_TASK_ROLE_ARN"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

    # Update the role's trust relationship
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "$NEW_POLICY"
    
    log "Successfully updated trust relationship for $ROLE_NAME"
done

log "All role trust relationships have been updated"

# Verify the updates
for ROLE_NAME in "${ROLES[@]}"; do
    log "Verifying trust relationship for role: $ROLE_NAME"
    aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json
done
