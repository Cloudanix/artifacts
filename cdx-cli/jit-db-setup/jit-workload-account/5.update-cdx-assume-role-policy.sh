#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Prompt for required inputs
read -p "Enter the AWS Account ID to connect: " CONNECTED_ACCOUNT_ID
read -p "Enter the CDX Role in the connected account: " CDX_ROLE

# Define the IAM Role Name and Policy Name
ROLE_NAME="cdx-ECSTaskRole"
POLICY_NAME="cdx-ECSRDSAssumeRolePolicy"

# Get the policy ARN
log "Fetching policy ARN for $POLICY_NAME"
POLICY_ARN=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyName=='$POLICY_NAME'].PolicyArn" --output text)

if [ -z "$POLICY_ARN" ]; then
    log "Error: Policy $POLICY_NAME is not attached to role $ROLE_NAME."
    exit 1
fi

log "Found policy ARN: $POLICY_ARN"

# Get the current policy document
log "Fetching current policy document"
CURRENT_POLICY=$(aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id $(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text) --query 'PolicyVersion.Document' --output json)

# Add new resource to the existing policy
UPDATED_POLICY=$(echo "$CURRENT_POLICY" | jq '.Statement[0].Resource += ["arn:aws:iam::'$CONNECTED_ACCOUNT_ID':role/'$CDX_ROLE'"]')

# Create a new policy version (AWS requires a new version instead of modifying the existing one)
log "Creating a new policy version"
aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$UPDATED_POLICY" --set-as-default

log "Successfully updated assume role policy for $ROLE_NAME"

# Verify the update
log "Verifying updated policy"
aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id $(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text) --query 'PolicyVersion.Document' --output json
