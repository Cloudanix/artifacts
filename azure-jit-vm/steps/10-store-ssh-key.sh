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

# store_user_key OS_USER KEY_FILE
#   Writes <vm-name>-<user> and, when the VM has a vmId, <vmId>-<user>.
store_user_key() {
    local os_user="$1" key_file="$2" name_secret id_secret
    if [[ ! -f "$key_file" ]]; then
        error "Key file does not exist for $os_user: $key_file"
        return 1
    fi
    name_secret="$(azure_key_secret_name "$TARGET_VM_NAME" "$os_user")"
    set_secret_file "$KV_KEYS" "$name_secret" "$key_file" || return 1
    echo "Stored target key as $name_secret in $KV_KEYS"
    if [[ -n "$VM_ID" && "$VM_ID" != "$TARGET_VM_NAME" ]]; then
        id_secret="$(azure_key_secret_name "$VM_ID" "$os_user")"
        set_secret_file "$KV_KEYS" "$id_secret" "$key_file" || return 1
        echo "Stored target key as $id_secret in $KV_KEYS"
    fi
    LAST_SECRET="$name_secret"
}

VM_ID="$(az vm show --resource-group "$TARGET_VM_RG" --name "$TARGET_VM_NAME" --query vmId -o tsv)"
LAST_SECRET=""
if [[ -n "${TARGET_VM_USERS:-}" ]]; then
    while IFS=$'\t' read -r os_user key_file; do
        [[ -n "$os_user" ]] || continue
        store_user_key "$os_user" "$key_file" || exit 1
    done < <(printf '%s' "$TARGET_VM_USERS" | jq -r '.[] | [.user, .key] | @tsv')
else
    store_user_key "$TARGET_VM_OS_USER" "$TARGET_SSH_PRIVATE_KEY_FILE" || exit 1
fi
az account set --subscription "$SUBSCRIPTION_ID"

echo "OUTPUT:SSH_SECRET_NAME=$LAST_SECRET"
