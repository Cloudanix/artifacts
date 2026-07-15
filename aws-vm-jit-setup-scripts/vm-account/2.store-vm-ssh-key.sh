#!/bin/bash
set -e

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

echo "=== Store VM SSH Key in Secrets Manager ==="
echo ""
echo "Stores/updates an SSH private key in the shared secret"
echo "used by the sshpiper container. Keys are stored as JSON"
echo "with instance-id as the key."
echo ""

PROJECT_NAME=$(prompt_with_default "Project Name" "cdx-jit-vm")
SECRET_NAME="${PROJECT_NAME}-ssh-keys"
INSTANCE_ID=$(prompt_with_default "EC2 Instance ID (key identifier)" "")
KEY_FILE=$(prompt_with_default "Path to SSH private key file" "/tmp/target-key.pem")
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")

if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: Instance ID is required."
    exit 1
fi

# Expand tilde in path
KEY_FILE="${KEY_FILE/#\~/$HOME}"

if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: Key file not found: $KEY_FILE"
    exit 1
fi

# Read the SSH key content
SSH_KEY_CONTENT=$(cat "$KEY_FILE")

echo ""
echo "Secret Name:  $SECRET_NAME"
echo "Instance ID:  $INSTANCE_ID"
echo "Key File:     $KEY_FILE"
echo "Region:       $AWS_REGION"
echo ""
# Check if secret already exists
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "Secret exists. Adding/updating key for instance: $INSTANCE_ID"

    # Get current secret value
    CURRENT_JSON=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_NAME" \
        --region "$AWS_REGION" \
        --query 'SecretString' --output text 2>/dev/null || echo "{}")

    # Add/update the instance key in the JSON
    UPDATED_JSON=$(echo "$CURRENT_JSON" | jq --arg id "$INSTANCE_ID" --arg key "$SSH_KEY_CONTENT" \
        '. + {($id): $key}')

    aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --secret-string "$UPDATED_JSON" \
        --region "$AWS_REGION" > /dev/null

    echo "Updated secret with key for: $INSTANCE_ID"
else
    echo "Creating new secret: $SECRET_NAME"

    # Create JSON with the first instance key
    SECRET_JSON=$(jq -n --arg id "$INSTANCE_ID" --arg key "$SSH_KEY_CONTENT" \
        '{($id): $key}')

    aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "SSH keys for target VMs (instance-id → private key)" \
        --secret-string "$SECRET_JSON" \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" \
        --region "$AWS_REGION" > /dev/null

    echo "Created secret with key for: $INSTANCE_ID"
fi

echo ""
echo "Done. Secret: $SECRET_NAME"
echo "Instance keys stored:"
aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
    --query 'SecretString' --output text | jq -r 'keys[]' | sed 's/^/  - /'
echo ""
echo "The vmproxyserver container reads this secret via CDX_VM_SECRETS_MANAGER_NAME."
