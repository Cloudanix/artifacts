#!/bin/bash

set -e  # Exit on error

# Store the policy documents in files
cat << 'EOF' > permission-set-policy.json
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
            "Resource": "*"
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
            "Resource": "*"
        }
    ]
}
EOF

# Variables
INSTANCE_ARN="$1"
PERMISSION_SET_NAME="EcsSsmAccess"
ACCOUNT_ID_2="$2"

echo "Step 1: Creating Permission Set..."
# Create the Permission Set and capture its ARN directly
PERMISSION_SET_ARN=$(aws sso-admin create-permission-set \
    --instance-arn $INSTANCE_ARN \
    --name $PERMISSION_SET_NAME \
    --description "Custom permission set for ECS and SSM access" \
    --session-duration "PT8H" \
    --query 'PermissionSet.PermissionSetArn' \
    --output text)

echo "Created Permission Set ARN: $PERMISSION_SET_ARN"

echo "Step 2: Adding inline policy..."
# Put the inline policy to the Permission Set
aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn $INSTANCE_ARN \
    --permission-set-arn $PERMISSION_SET_ARN \
    --inline-policy file://permission-set-policy.json

echo "Step 3: Verifying permission set exists..."
aws sso-admin describe-permission-set \
    --instance-arn $INSTANCE_ARN \
    --permission-set-arn $PERMISSION_SET_ARN

echo "Setup completed! To assign users/groups to this permission set, use the IAM Identity Center console or run additional AWS CLI commands."
