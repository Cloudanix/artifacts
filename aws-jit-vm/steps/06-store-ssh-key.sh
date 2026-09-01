#!/usr/bin/env bash
# =============================================================================
# Step: Store VM SSH Key in Secrets Manager
# =============================================================================
# Run in the VM TARGET account. Creates or updates a Secrets Manager secret
# that stores SSH private keys for target VMs. Keys are stored as JSON with
# instance-id as the key name, matching what the JIT proxy expects
# (CDX_VM_SECRETS_MANAGER_NAME = <project>-ssh-keys).
#
# The instance ID and key can be supplied via env (SSH_KEY_INSTANCE_ID +
# SSH_KEY_FILE) OR entered interactively at the prompt. If neither is given
# the secret is created as an empty placeholder and keys can be added later.
#
# Required env vars:
#   AWS_REGION, PROJECT_NAME
#
# Optional env vars:
#   SSH_KEY_INSTANCE_ID — the EC2 instance ID (key identifier)
#   SSH_KEY_FILE        — path to the SSH private key file
#
# Outputs:
#   OUTPUT:SSH_KEY_SECRET_ARN
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
export CDX_PURPOSE=jit_vm

require_env AWS_REGION PROJECT_NAME

export AWS_DEFAULT_REGION="$AWS_REGION"
SECRET_NAME="${PROJECT_NAME}-ssh-keys"

info "Secret Name: $SECRET_NAME"
info "Region: $AWS_REGION"

# =============================================================================
# CHECK / CREATE SECRET (idempotent)
# =============================================================================

step "Secrets Manager"

SECRET_ARN=""
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" > /dev/null 2>&1; then
    SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
        --query 'ARN' --output text)
    ok "Secret exists: $SECRET_NAME ($SECRET_ARN)"
else
    SECRET_ARN=$(aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "SSH keys for target VMs (instance-id → private key)" \
        --secret-string '{}' \
        --tags $(cdx_tags_kv) \
        --query 'ARN' --output text)
    ok "Secret created: $SECRET_NAME ($SECRET_ARN)"
fi

# =============================================================================
# COLLECT KEY (interactive if not provided via env)
# =============================================================================

# If not supplied via env, offer to add a key now.
if [[ -z "${SSH_KEY_INSTANCE_ID:-}" || -z "${SSH_KEY_FILE:-}" ]]; then
    echo ""
    if prompt_yes_no "Add an SSH private key for a target VM now?" "y"; then
        # Instance ID — must look like an EC2 instance ID (i-<hex>), so a stray
        # 'y' or typo can't be silently stored as the key name.
        while true; do
            read -erp "  Target EC2 Instance ID (e.g. i-0abc123def456...): " SSH_KEY_INSTANCE_ID
            SSH_KEY_INSTANCE_ID="$(printf '%s' "${SSH_KEY_INSTANCE_ID:-}" | xargs)"
            if [[ "$SSH_KEY_INSTANCE_ID" =~ ^i-[0-9a-f]{8,}$ ]]; then
                break
            fi
            warn "That doesn't look like an instance ID. Expected 'i-' followed by hex (e.g. i-0abc123def456789)."
        done
        # Key source: file path or paste
        echo "  Provide the private key by:"
        echo "    1) Path to a .pem/.key file (default)"
        echo "    2) Paste the key contents"
        key_src=""
        read -erp "  Select [1-2] (default 1): " key_src
        key_src="${key_src:-1}"
        if [[ "$key_src" == "2" ]]; then
            echo "  Paste the PRIVATE KEY including the BEGIN and END lines."
            echo "  Entry finishes automatically at the '-----END ...-----' line"
            echo "  (or press Ctrl-D on an empty line)."
            SSH_KEY_CONTENT=""
            while IFS= read -r _kline || [[ -n "$_kline" ]]; do
                SSH_KEY_CONTENT+="${_kline}"$'\n'
                # Stop right after the END marker so no Ctrl-D is required.
                [[ "$_kline" == *"-----END"*"-----"* ]] && break
            done
            # Trim leading/trailing blank lines.
            SSH_KEY_CONTENT="$(printf '%s' "$SSH_KEY_CONTENT" | sed -e '/./,$!d')"
        else
            while [[ -z "${SSH_KEY_FILE:-}" ]]; do
                read -erp "  Path to private key file: " SSH_KEY_FILE
                SSH_KEY_FILE="$(printf '%s' "${SSH_KEY_FILE:-}" | xargs)"
                # Expand a leading ~ to $HOME
                SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
                if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
                    warn "File not found: $SSH_KEY_FILE"
                    SSH_KEY_FILE=""
                fi
            done
            SSH_KEY_CONTENT="$(cat "$SSH_KEY_FILE")"
        fi
    fi
elif [[ -n "${SSH_KEY_FILE:-}" ]]; then
    # Env-driven path
    SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        error "Key file not found: $SSH_KEY_FILE"
        exit 1
    fi
    SSH_KEY_CONTENT="$(cat "$SSH_KEY_FILE")"
fi

# =============================================================================
# STORE KEY (merge into existing secret JSON, keyed by instance ID)
# =============================================================================

if [[ -n "${SSH_KEY_INSTANCE_ID:-}" && -n "${SSH_KEY_CONTENT:-}" ]]; then
    step "Store SSH Key"
    info "Instance ID: $SSH_KEY_INSTANCE_ID"

    CURRENT_JSON=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_NAME" \
        --query 'SecretString' --output text 2>/dev/null || echo "{}")
    [[ -z "$CURRENT_JSON" || "$CURRENT_JSON" == "None" ]] && CURRENT_JSON="{}"

    UPDATED_JSON=$(printf '%s' "$CURRENT_JSON" | jq \
        --arg id "$SSH_KEY_INSTANCE_ID" --arg key "$SSH_KEY_CONTENT" \
        '. + {($id): $key}')

    aws secretsmanager put-secret-value \
        --secret-id "$SECRET_NAME" \
        --secret-string "$UPDATED_JSON" > /dev/null

    ok "Key stored for instance: $SSH_KEY_INSTANCE_ID"
else
    info "No key provided — secret left as-is (placeholder or existing keys)."
    info "Add keys later: aws secretsmanager put-secret-value --secret-id $SECRET_NAME ..."
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "SSH key secret ready"
echo "OUTPUT:SSH_KEY_SECRET_ARN=${SECRET_ARN}"
