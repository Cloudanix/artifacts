#!/usr/bin/env bash
# =============================================================================
# Step 10 — Store the target SSH private key
# =============================================================================
# The proxy looks up <vm-name>-<os-user> in the keys Key Vault, then the VM
# name alone. This writes the per-user name. The key file is passed to
# Key Vault directly and is not printed.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_target || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

SECRET_NAME="$(azure_key_secret_name "$TARGET_VM_NAME" "$TARGET_VM_OS_USER")"
set_secret_file "$KV_KEYS" "$SECRET_NAME" "$TARGET_SSH_PRIVATE_KEY_FILE" || exit 1

echo "Stored target key as $SECRET_NAME in $KV_KEYS"
echo "OUTPUT:SSH_SECRET_NAME=$SECRET_NAME"
