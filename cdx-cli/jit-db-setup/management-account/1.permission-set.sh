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
SESSION_DURATION="PT8H"
SID_ACCOUNT_ID=$(echo "${JIT_ACCOUNT_ID}" | tr -cd '[:alnum:]')
SID_CLUSTER_NAME=$(echo "${JIT_CLUSTER_NAME}" | tr -cd '[:alnum:]')

# Build the new statements for this run
cat << EOF > new-statements.json
[
    {
        "Sid": "SSMSessionAndCommandPolicy${SID_ACCOUNT_ID}${SID_CLUSTER_NAME}",
        "Effect": "Allow",
        "Action": [
            "ssm:StartSession",
            "ssm:DescribeSessions",
            "ssm:TerminateSession",
            "ssm:SendCommand"
        ],
        "Resource": [
            "arn:aws:ecs:${JIT_REGION}:${JIT_ACCOUNT_ID}:cluster/${JIT_CLUSTER_NAME}",
            "arn:aws:ecs:${JIT_REGION}:${JIT_ACCOUNT_ID}:task/${JIT_CLUSTER_NAME}/*",
            "arn:aws:ec2:${JIT_REGION}:${JIT_ACCOUNT_ID}:instance/*",
            "arn:aws:ssm:*:*:document/*",
            "arn:aws:ssm:*:*:session/*"
        ]
    },
    {
        "Sid": "ECSDescribeAndListTasksServices${SID_ACCOUNT_ID}${SID_CLUSTER_NAME}",
        "Effect": "Allow",
        "Action": [
            "ecs:DescribeTasks",
            "ecs:ListTasks",
            "ecs:DescribeServices",
            "ecs:ListServices"
        ],
        "Resource": [
            "arn:aws:ecs:${JIT_REGION}:${JIT_ACCOUNT_ID}:cluster/${JIT_CLUSTER_NAME}",
            "arn:aws:ecs:${JIT_REGION}:${JIT_ACCOUNT_ID}:task/${JIT_CLUSTER_NAME}/*",
            "arn:aws:ecs:${JIT_REGION}:${JIT_ACCOUNT_ID}:service/${JIT_CLUSTER_NAME}/*",
            "arn:aws:ecs:${JIT_REGION}:${JIT_ACCOUNT_ID}:container-instance/${JIT_CLUSTER_NAME}/*"
        ]
    }
]
EOF

# Confirmation
echo -e "\n=== Configuration Summary ==="
echo "SSO Instance ARN: $INSTANCE_ARN"
echo "Permission Set Name: $PERMISSION_SET_NAME"
echo "JIT Account ID: $JIT_ACCOUNT_ID"
echo "JIT Region: $JIT_REGION"
echo "JIT Cluster Name: $JIT_CLUSTER_NAME"

# --- Helper: Find existing permission set by name ---
find_permission_set_arn() {
    local next_token=""
    while true; do
        if [ -z "$next_token" ]; then
            RESPONSE=$(aws sso-admin list-permission-sets \
                --instance-arn "$INSTANCE_ARN" \
                --output json)
        else
            RESPONSE=$(aws sso-admin list-permission-sets \
                --instance-arn "$INSTANCE_ARN" \
                --next-token "$next_token" \
                --output json)
        fi

        PERMISSION_SET_ARNS=$(echo "$RESPONSE" | jq -r '.PermissionSets[]')

        for arn in $PERMISSION_SET_ARNS; do
            NAME=$(aws sso-admin describe-permission-set \
                --instance-arn "$INSTANCE_ARN" \
                --permission-set-arn "$arn" \
                --query 'PermissionSet.Name' \
                --output text 2>/dev/null)
            if [ "$NAME" == "$PERMISSION_SET_NAME" ]; then
                echo "$arn"
                return 0
            fi
        done

        next_token=$(echo "$RESPONSE" | jq -r '.NextToken // empty')
        if [ -z "$next_token" ]; then
            break
        fi
    done
    return 1
}

# --- Step 1: Create or find existing Permission Set ---
echo ""
echo "Step 1: Checking if Permission Set '$PERMISSION_SET_NAME' already exists..."

PERMISSION_SET_ARN=$(find_permission_set_arn 2>/dev/null || true)

if [ -n "$PERMISSION_SET_ARN" ]; then
    echo "Found existing Permission Set: $PERMISSION_SET_ARN"
else
    echo "Permission Set not found. Creating..."
    PERMISSION_SET_ARN=$(aws sso-admin create-permission-set \
        --instance-arn "$INSTANCE_ARN" \
        --name "$PERMISSION_SET_NAME" \
        --description "Custom permission set for ECS and SSM access" \
        --session-duration "$SESSION_DURATION" \
        --query 'PermissionSet.PermissionSetArn' \
        --output text)
    echo "Created Permission Set ARN: $PERMISSION_SET_ARN"
fi

# --- Step 2: Fetch existing inline policy (if any) and merge new statements ---
echo ""
echo "Step 2: Fetching existing inline policy..."

EXISTING_POLICY=$(aws sso-admin get-inline-policy-for-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --query 'InlinePolicy' \
    --output text 2>/dev/null || true)

if [ -z "$EXISTING_POLICY" ] || [ "$EXISTING_POLICY" == "None" ] || [ "$EXISTING_POLICY" == "" ]; then
    echo "No existing inline policy found. Creating fresh policy."
    # Build policy from new statements only
    jq -n --slurpfile stmts new-statements.json '{
        Version: "2012-10-17",
        Statement: $stmts[0]
    }' > permission-set-policy.json
else
    echo "Existing inline policy found. Merging new statements..."
    # Save existing policy to file
    echo "$EXISTING_POLICY" > existing-policy.json

    # Merge: add new statements, replacing any with the same Sid
    jq --slurpfile new_stmts new-statements.json '
        # Collect Sids from new statements
        ($new_stmts[0] | map(.Sid)) as $new_sids |
        # Keep existing statements whose Sid is NOT in the new set
        .Statement = ([.Statement[] | select(.Sid as $s | $new_sids | index($s) | not)] + $new_stmts[0])
    ' existing-policy.json > permission-set-policy.json

    rm -f existing-policy.json
fi

echo "Merged policy:"
jq . permission-set-policy.json

# --- Step 3: Put the merged inline policy ---
echo ""
echo "Step 3: Applying inline policy to permission set..."

aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --inline-policy file://permission-set-policy.json

# --- Step 4: Verify ---
echo ""
echo "Step 4: Verifying permission set..."
aws sso-admin describe-permission-set \
    --instance-arn "$INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN"

# Cleanup temp files
rm -f new-statements.json permission-set-policy.json

echo ""
echo "Setup completed! New statements have been added without affecting existing ones."
