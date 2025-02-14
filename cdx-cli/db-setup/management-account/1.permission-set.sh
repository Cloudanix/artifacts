#!/bin/bash

set -e  # Exit on error

# Function to prompt user for input with a default value
prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# Interactive Configuration
echo "=== AWS SSO Permission Set Setup ==="

# Prompt for SSO Instance ARN
INSTANCE_ARN=$(prompt_with_default "Enter SSO Instance ARN" "arn:aws:sso:::instance/ssoins-722367552337aabd")

# Prompt for Permission Set Name
PERMISSION_SET_NAME=$(prompt_with_default "Enter Permission Set Name" "cdx-EcsSsmAccess")

# Prompt for JIT Account Details
JIT_ACCOUNT_ID=$(prompt_with_default "Enter JIT Account ID" "")
JIT_REGION=$(prompt_with_default "Enter JIT Account Region" "ap-south-1")
JIT_CLUSTER_NAME=$(prompt_with_default "Enter JIT ECS Cluster Name" "cdx-jit-db-cluster")

# Session Duration (default 8 hours)
SESSION_DURATION=$(prompt_with_default "Enter Session Duration (format PT#H)" "PT8H")

# Create dynamic policy with user-specified cluster
cat << EOF > permission-set-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SSMSessionAndCommandPolicy",
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession",
                "ssm:DescribeSessions",
                "ssm:TerminateSession",
                "ssm:SendCommand"
            ],
            "Resource": [
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:cluster/$JIT_CLUSTER_NAME",
                "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:task/$JIT_CLUSTER_NAME/*",
            ]
        },
        {
            "Sid": "ECSDescribeAndListTasksServices",
            "Effect": "Allow",
            "Action": [
                "ecs:DescribeTasks",
                "ecs:ListTasks",
                "ecs:DescribeServices",
                "ecs:ListServices"
            ],
            "Resource": "arn:aws:ecs:$JIT_REGION:$JIT_ACCOUNT_ID:cluster/$JIT_CLUSTER_NAME"
        }
    ]
}
EOF

# Confirmation
echo -e "\n=== Configuration Summary ==="
echo "SSO Instance ARN: $INSTANCE_ARN"
echo "Permission Set Name: $PERMISSION_SET_NAME"
echo "JIT Account ID: $JIT_ACCOUNT_ID"
echo "JIT Region: $JIT_REGION"
echo "JIT Cluster Name: $JIT_CLUSTER_NAME"

echo "Step 1: Creating Permission Set..."
# Create the Permission Set and capture its ARN directly
PERMISSION_SET_ARN=$(aws sso-admin create-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --name "$PERMISSION_SET_NAME" \
    --description "Custom permission set for ECS and SSM access" \
    --session-duration "$SESSION_DURATION" \
    --query 'PermissionSet.PermissionSetArn' \
    --output text)

echo "Created Permission Set ARN: $PERMISSION_SET_ARN"

echo "Step 2: Adding inline policy..."
# Put the inline policy to the Permission Set
aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --inline-policy file://permission-set-policy.json

echo "Step 3: Verifying permission set exists..."
aws sso-admin describe-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN"

echo "Setup completed!"
