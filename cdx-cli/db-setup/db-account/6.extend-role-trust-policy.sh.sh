#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Prompt for required inputs
read -p "Enter the CDX Role Name: " ROLE_NAME
read -p "Enter the AWS Account ID for ECS : " JIT_DB_ACCOUNT_ID
JIT_DB_TASK_ROLE_ARN="arn:aws:iam::${JIT_DB_ACCOUNT_ID}:role/cdx-ECSTaskRole"

# Fetch the current trust policy
log "Fetching current trust policy for role: $ROLE_NAME"
CURRENT_POLICY=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json)

# Remove escaping and parse JSON
CURRENT_POLICY=$(echo "$CURRENT_POLICY" | jq 'del(.Statement[] | select(.Principal.AWS == "'$JIT_DB_TASK_ROLE_ARN'"))')

# New statement to add
NEW_STATEMENT=$(jq -n --arg role_arn "$JIT_DB_TASK_ROLE_ARN" '{ "Effect": "Allow", "Principal": { "AWS": $role_arn }, "Action": "sts:AssumeRole" }')

# Merge new statement into the existing policy
UPDATED_POLICY=$(echo "$CURRENT_POLICY" | jq ".Statement += [$NEW_STATEMENT]")

# Update the role's trust relationship
log "Updating trust relationship for role: $ROLE_NAME"
aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$UPDATED_POLICY"

log "Successfully updated trust relationship for $ROLE_NAME"

# Verify the update
log "Verifying updated trust relationship for role: $ROLE_NAME"
aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json