#!/usr/bin/env bash
# =============================================================================
# Step 10 — Store the target SSH private key
# =============================================================================
# The validate API sends the Azure VM ID (vmId) as vmInstanceId. The proxy
# looks up <vmId>-<os-user>, then the vmId alone. An ARM resource id is reduced
# to the VM name, so the name-based secret is stored as well. The key file is
# passed to Key Vault directly and is not printed.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_target || exit 1
use_target_subscription

SECRET_NAME="$(azure_key_secret_name "$TARGET_VM_NAME" "$TARGET_VM_OS_USER")"
set_secret_file "$KV_KEYS" "$SECRET_NAME" "$TARGET_SSH_PRIVATE_KEY_FILE" || exit 1
echo "Stored target key as $SECRET_NAME in $KV_KEYS"

VM_ID="$(az vm show --resource-group "$TARGET_VM_RG" --name "$TARGET_VM_NAME" --query vmId -o tsv)"
if [[ -n "$VM_ID" && "$VM_ID" != "$TARGET_VM_NAME" ]]; then
    VMID_SECRET="$(azure_key_secret_name "$VM_ID" "$TARGET_VM_OS_USER")"
    set_secret_file "$KV_KEYS" "$VMID_SECRET" "$TARGET_SSH_PRIVATE_KEY_FILE" || exit 1
    echo "Stored target key as $VMID_SECRET in $KV_KEYS"
fi
az account set --subscription "$SUBSCRIPTION_ID"

echo "OUTPUT:SSH_SECRET_NAME=$SECRET_NAME"
