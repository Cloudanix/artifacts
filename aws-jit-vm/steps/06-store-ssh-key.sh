#!/usr/bin/env bash
# =============================================================================
# Step: Store VM SSH Key in Secrets Manager
# =============================================================================
# Run in the VM TARGET account. Creates or updates a Secrets Manager secret
# that stores SSH private keys for target VMs. Keys are stored as JSON with
# instance-id as the key name.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME
#
# Optional env vars:
#   SSH_KEY_INSTANCE_ID — the EC2 instance ID (key identifier)
#   SSH_KEY_FILE — path to the SSH private key file
#
# Outputs:
#   OUTPUT:SSH_KEY_SECRET_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PROJECT_NAME

# =============================================================================
# CONFIGURATION
# =============================================================================

SECRET_NAME="${PROJECT_NAME}-ssh-keys"

info "Secret Name: $SECRET_NAME"
info "Region: $AWS_REGION"

# =============================================================================
# CHECK / CREATE SECRET (idempotent)
# =============================================================================

step "Secrets Manager"

SECRET_ARN=""
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
    SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
        --query 'ARN' --output text --region "$AWS_REGION")
    ok "Secret exists: $SECRET_NAME ($SECRET_ARN)"
else
    # Create the secret with an empty JSON object as placeholder
    SECRET_ARN=$(aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "SSH keys for target VMs (instance-id → private key)" \
        --secret-string '{}' \
        --tags "Key=Purpose,Value=vm-jit" "Key=created_by,Value=cloudanix" \
        --region "$AWS_REGION" \
        --query 'ARN' --output text)
    ok "Secret created: $SECRET_NAME ($SECRET_ARN)"
fi

# =============================================================================
# STORE KEY (if provided)
# =============================================================================

if [[ -n "${SSH_KEY_INSTANCE_ID:-}" && -n "${SSH_KEY_FILE:-}" ]]; then
    step "Store SSH Key"

    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        error "Key file not found: $SSH_KEY_FILE"
        exit 1
    fi

    SSH_KEY_CONTENT=$(cat "$SSH_KEY_FILE")
    info "Instance ID: $SSH_KEY_INSTANCE_ID"

    # Get current secret value and merge
    CURRENT_JSON=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_NAME" \
        --region "$AWS_REGION" \
        --query 'SecretString' --output text 2>/dev/null || echo "{}")

    UPDATED_JSON=$(echo "$CURRENT_JSON" | jq --arg id "$SSH_KEY_INSTANCE_ID" --arg key "$SSH_KEY_CONTENT" \
        '. + {($id): $key}')

    aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --secret-string "$UPDATED_JSON" \
        --region "$AWS_REGION" > /dev/null

    ok "Key stored for instance: $SSH_KEY_INSTANCE_ID"
else
    info "No SSH_KEY_INSTANCE_ID/SSH_KEY_FILE provided — secret created as empty placeholder"
    info "Add keys later: aws secretsmanager update-secret --secret-id $SECRET_NAME ..."
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "SSH key secret ready"
echo "OUTPUT:SSH_KEY_SECRET_ARN=${SECRET_ARN}"
