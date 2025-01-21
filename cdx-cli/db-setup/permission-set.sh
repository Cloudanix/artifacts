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
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-722367552337aabd"
PERMISSION_SET_NAME="EcsSsmAccess"
ACCOUNT_ID_2="952490538873"

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

echo "Step 3: Starting provisioning..."
# Provision the Permission Set and get the provisioning status
PROVISION_STATUS=$(aws sso-admin provision-permission-set \
    --instance-arn $INSTANCE_ARN \
    --permission-set-arn $PERMISSION_SET_ARN \
    --target-type AWS_ACCOUNT \
    --target-id $ACCOUNT_ID_2 \
    --output json)

REQUEST_ID=$(echo $PROVISION_STATUS | jq -r '.PermissionSetProvisioningStatus.RequestId')
echo "Provisioning Request ID: $REQUEST_ID"

echo "Step 4: Monitoring provisioning status..."
while true; do
    STATUS=$(aws sso-admin describe-permission-set-provisioning-status \
        --instance-arn $INSTANCE_ARN \
        --provision-permission-set-request-id $REQUEST_ID \
        --query 'PermissionSetProvisioningStatus.Status' \
        --output text)
    
    echo "Current status: $STATUS"
    
    if [ "$STATUS" = "SUCCEEDED" ]; then
        echo "Provisioning completed successfully!"
        break
    elif [ "$STATUS" = "FAILED" ]; then
        echo "Provisioning failed. Getting failure details..."
        aws sso-admin describe-permission-set-provisioning-status \
            --instance-arn $INSTANCE_ARN \
            --provision-permission-set-request-id $REQUEST_ID
        exit 1
    fi
    
    sleep 5
done

echo "Step 5: Verifying permission set exists..."
aws sso-admin describe-permission-set \
    --instance-arn $INSTANCE_ARN \
    --permission-set-arn $PERMISSION_SET_ARN

echo "Setup completed! To assign users/groups to this permission set, use the IAM Identity Center console or run additional AWS CLI commands."

# #TODO : provision logic for group/user of JIT Account 
