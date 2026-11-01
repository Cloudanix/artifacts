#!/usr/bin/env bash
# =============================================================================
# Azure JIT VM — Shared helpers for step scripts
# =============================================================================
# Sourced by every steps/*.sh and by ../refresh-forwarders.sh. Derives all
# resource names from NAME_PREFIX so the same inputs always map to the same
# resources. The leading underscore keeps this file out of the step list.
# =============================================================================

_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HELPERS_DIR/../../lib/common.sh"

# -----------------------------------------------------------------------------
# Derived resource names
# -----------------------------------------------------------------------------
# Storage account names: 3-24 lowercase alphanumerics, no dashes.
# Key Vault names: 3-24 chars, letters/digits/dashes. With NAME_PREFIX capped
# at 12 chars, every name below stays inside those limits.

RG="${NAME_PREFIX}-jit-vm-rg"
VNET="${NAME_PREFIX}-jit-vm-vnet"
JUMP_SUBNET="${NAME_PREFIX}-jump-subnet"
ACI_SUBNET="${NAME_PREFIX}-aci-subnet"
VM_SUBNET="${NAME_PREFIX}-vm-subnet"
JUMP_NSG="${NAME_PREFIX}-jump-nsg"
JUMP_VM="${NAME_PREFIX}-jit-jump"
JUMP_PIP="${NAME_PREFIX}-jit-jump-pip"
STORAGE="${NAME_PREFIX}jitvmstore"
KV_ENV="${NAME_PREFIX}-jitenv-kv"
KV_KEYS="${NAME_PREFIX}-jitkeys-kv"
IDENTITY="${NAME_PREFIX}-jit-identity"
ACI_SSHPIPER="${NAME_PREFIX}-jit-sshpiper"
ACI_VMPROXY="${NAME_PREFIX}-jit-vmproxy"
ACI_LOGGING="${NAME_PREFIX}-jit-logging"
WORK_SHARE="sshpiper-workingdir"
RECORDINGS_SHARE="sshpiper-recordings"

# Asset tags on every resource this installer creates. The jump VM also keeps
# owner/service/purpose so the CLI can discover it when jump_vm_tags is unset.
CDX_ASSET_TAG_ARGS=(asset-owner=Cloudanix asset-service=CloudSecurity asset-purpose=Security-Monitoring)
CDX_JUMP_TAG_ARGS=(owner=cloudanix service=jump-box purpose=cdx-jit-vm "${CDX_ASSET_TAG_ARGS[@]}")

# apply_asset_tags ID [ID...]
#   Adds the asset tags without removing tags already on the resource.
apply_asset_tags() {
    local id
    for id in "$@"; do
        [[ -n "$id" && "$id" != "null" ]] || continue
        az resource tag --ids "$id" --is-incremental true \
            --tags "${CDX_ASSET_TAG_ARGS[@]}" --only-show-errors >/dev/null
    done
}

# apply_jump_tags VM_ID
#   Discovery tags plus the asset tags, on the jump VM only.
apply_jump_tags() {
    [[ -n "$1" && "$1" != "null" ]] || return 0
    az resource tag --ids "$1" --is-incremental true \
        --tags "${CDX_JUMP_TAG_ARGS[@]}" --only-show-errors >/dev/null
}

# Fixed address plan. Change here if it collides with the customer's networks.
VNET_CIDR="10.30.0.0/16"
JUMP_SUBNET_CIDR="10.30.1.0/24"
ACI_SUBNET_CIDR="10.30.2.0/24"
VM_SUBNET_CIDR="10.30.3.0/24"

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

# ssh_cidrs
#   Prints each SSH_ALLOWED_CIDRS entry on its own line, spaces removed.
ssh_cidrs() {
    tr ',' '\n' <<< "$SSH_ALLOWED_CIDRS" | tr -d ' \t' | sed '/^$/d'
}

# validate_inputs
#   Fails closed on anything that would create an unsafe or unusable deployment.
validate_inputs() {
    require_env SUBSCRIPTION_ID LOCATION NAME_PREFIX SSH_ALLOWED_CIDRS \
        OPERATOR_OBJECT_ID JUMP_VM_ADMIN_USERNAME JUMP_VM_SSH_PUBLIC_KEY_FILE \
        IMAGE_REGISTRY ACR_RESOURCE_ID IMAGE_TAG SSHPIPER_IMAGE VMPROXY_IMAGE \
        LOGGING_IMAGE CDX_API_BASE CDX_DC LOG_CONTAINER || return 1

    if [[ ! "$NAME_PREFIX" =~ ^[a-z][a-z0-9]{2,11}$ ]]; then
        error "NAME_PREFIX must be 3-12 characters: lowercase letters/digits, starting with a letter"
        return 1
    fi
    if ! validate_azure_subscription_id "$SUBSCRIPTION_ID"; then
        error "SUBSCRIPTION_ID is not a valid GUID"
        return 1
    fi
    if ! validate_azure_subscription_id "$OPERATOR_OBJECT_ID"; then
        error "OPERATOR_OBJECT_ID is not a valid object ID (GUID)"
        return 1
    fi
    if [[ "$IMAGE_TAG" == "latest" ]]; then
        error "IMAGE_TAG must be an immutable version, not 'latest'"
        return 1
    fi
    if [[ ! -f "$JUMP_VM_SSH_PUBLIC_KEY_FILE" ]]; then
        error "JUMP_VM_SSH_PUBLIC_KEY_FILE does not exist: $JUMP_VM_SSH_PUBLIC_KEY_FILE"
        return 1
    fi

    local cidr count=0
    while IFS= read -r cidr; do
        count=$((count + 1))
        if [[ "$cidr" == "0.0.0.0/0" ]]; then
            error "SSH_ALLOWED_CIDRS must not include 0.0.0.0/0"
            return 1
        fi
        if ! validate_cidr "$cidr"; then
            error "Invalid CIDR in SSH_ALLOWED_CIDRS: $cidr"
            return 1
        fi
    done < <(ssh_cidrs)
    if [[ $count -eq 0 ]]; then
        error "SSH_ALLOWED_CIDRS must contain at least one CIDR"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Azure helpers
# -----------------------------------------------------------------------------

# ensure_role PRINCIPAL_OBJECT_ID PRINCIPAL_TYPE ROLE SCOPE
#   Assigns ROLE at SCOPE unless that exact assignment already exists.
#   PRINCIPAL_TYPE is User or ServicePrincipal.
ensure_role() {
    local principal="$1" principal_type="$2" role="$3" scope="$4" existing
    existing="$(az role assignment list --assignee-object-id "$principal" \
        --role "$role" --scope "$scope" --query '[0].id' -o tsv)"
    if [[ -n "$existing" ]]; then
        ok "Role already assigned: $role"
        return 0
    fi
    az role assignment create --assignee-object-id "$principal" \
        --assignee-principal-type "$principal_type" \
        --role "$role" --scope "$scope" --only-show-errors >/dev/null
    ok "Role assigned: $role"
}

# azure_key_secret_name VM_NAME OS_USER
#   Matches the proxy: ARM ids reduce to the VM name, then "-<user>", with
#   dots and underscores replaced by hyphens.
azure_key_secret_name() {
    local vm="${1##*/}" user="$2"
    vm="${vm//./-}"
    vm="${vm//_/-}"
    user="${user//./-}"
    user="${user//_/-}"
    printf '%s-%s\n' "$vm" "$user"
}

# validate_target
#   Inputs for peering, NSG allow, and storing the target SSH key.
validate_target() {
    require_env SUBSCRIPTION_ID NAME_PREFIX TARGET_VM_NAME TARGET_VM_RG \
        TARGET_VM_OS_USER TARGET_SSH_PRIVATE_KEY_FILE || return 1
    [[ -f "$TARGET_SSH_PRIVATE_KEY_FILE" ]] || {
        error "TARGET_SSH_PRIVATE_KEY_FILE does not exist: $TARGET_SSH_PRIVATE_KEY_FILE"
        return 1
    }
    [[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9]{2,11}$ ]] || {
        error "NAME_PREFIX must be 3-12 characters: lowercase letters/digits, starting with a letter"
        return 1
    }
}

# set_secret VAULT NAME VALUE
#   Writes a Key Vault secret. The value goes through a 0600 temp file so it
#   never appears in the process list. Retries because a new RBAC grant can
#   take a short time to apply.
set_secret() {
    local vault="$1" name="$2" value="$3" tmp attempt
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    printf '%s' "$value" > "$tmp"
    for attempt in 1 2 3 4 5 6; do
        if az keyvault secret set --vault-name "$vault" --name "$name" \
            --file "$tmp" --tags "${CDX_ASSET_TAG_ARGS[@]}" --only-show-errors >/dev/null 2>&1; then
            rm -f "$tmp"
            ok "Secret set: $name"
            return 0
        fi
        sleep 10
    done
    rm -f "$tmp"
    error "Could not set secret $name in $vault (RBAC may still be propagating)"
    return 1
}

# set_secret_file VAULT NAME PATH
#   Same as set_secret, but the value is already a file (used for SSH keys).
set_secret_file() {
    local vault="$1" name="$2" path="$3" attempt
    chmod 600 "$path" 2>/dev/null || true
    for attempt in 1 2 3 4 5 6; do
        if az keyvault secret set --vault-name "$vault" --name "$name" \
            --file "$path" --tags "${CDX_ASSET_TAG_ARGS[@]}" --only-show-errors >/dev/null 2>&1; then
            ok "Secret set: $name"
            return 0
        fi
        sleep 10
    done
    error "Could not set secret $name in $vault (RBAC may still be propagating)"
    return 1
}

# use_target_subscription
#   Onboard and peering-accept steps run in the target subscription.
#   existing-vnet does not ask for one, so the hub subscription is the default.
use_target_subscription() {
    az account set --subscription "${TARGET_SUBSCRIPTION_ID:-$SUBSCRIPTION_ID}"
}
