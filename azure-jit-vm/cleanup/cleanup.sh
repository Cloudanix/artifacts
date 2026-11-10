#!/usr/bin/env bash
# =============================================================================
# Azure JIT VM — Cleanup (state optional)
# =============================================================================
# Removes the hub this setup created. Every name comes from NAME_PREFIX, so
# nothing outside that prefix is matched.
#
# Deletes:
#   - Peering cdx-{prefix}-to-hub in the target VNet (target subscription)
#   - Peering cdx-{prefix}-to-target on the hub VNet (the hub VNet, or the
#     existing VNet when the hub uses one)
#   - Bulk peerings recorded in .bulk-onboard-progress.json: cdx-{prefix}-to-hub
#     on each target VNet, and cdx-{prefix}-<hash> on the hub. A peering that
#     already existed under another name is left in place.
#   - AcrPull on the registry, granted to the proxy identity
#   - Resource group {prefix}-jit-vm-rg. This removes the hub VNet (for a new
#     VNet hub), jump VM and public IP, the three containers, the storage
#     account with the recordings, both Key Vaults, the managed identity, and
#     the role assignments made on resources in the group.
#
# Does not delete (printed at the end as manual steps):
#   - AllowCdxProxySsh on the target VM's network security group
#   - AllowOperatorSSH on a customer network security group (existing VNet)
#   - The target VM, the customer VNet and its subnets, the registry images
#   - Custom roles CDX JIT VM Read Access and CDX JIT VM SSH Access (shared)
#
# Called by: setup.sh --cleanup. Expects lib/common.sh and config.sh loaded.
# =============================================================================

get_cfg() {
    if [[ -f "$STATE_FILE" ]]; then
        get_config_value "$STATE_FILE" "$1"
    fi
}

NAME_PREFIX="$(get_cfg NAME_PREFIX)"
if [[ -z "$NAME_PREFIX" ]]; then
    NAME_PREFIX="$(prompt_with_default "Name prefix used at setup" "cdxjit")"
fi
if [[ ! "$NAME_PREFIX" =~ ^[a-z][a-z0-9]{2,11}$ ]]; then
    error "NAME_PREFIX must be 3-12 characters: lowercase letters/digits, starting with a letter"
    exit 1
fi

HUB_SUB="$(get_cfg SUBSCRIPTION_ID)"
if [[ -z "$HUB_SUB" ]]; then
    HUB_SUB="$(az account show --query id -o tsv)"
fi

RG="${NAME_PREFIX}-jit-vm-rg"
VNET="${NAME_PREFIX}-jit-vm-vnet"
IDENTITY="${NAME_PREFIX}-jit-identity"
LOG_CONTAINER="$(get_cfg LOG_CONTAINER)"
[[ -z "$LOG_CONTAINER" ]] && LOG_CONTAINER="jit-vm-logs"
PEERING_HUB_SIDE="cdx-${NAME_PREFIX}-to-target"
PEERING_TARGET_SIDE="cdx-${NAME_PREFIX}-to-hub"

info "Hub subscription: $HUB_SUB | Resource group: $RG"

# -----------------------------------------------------------------------------
# Confirm before anything is deleted. Recordings are audit records, and the
# storage account that holds them is inside the group.
# -----------------------------------------------------------------------------
az account set --subscription "$HUB_SUB"

if [[ "$(az group exists --name "$RG")" == "true" ]]; then
    warn "Deleting $RG removes the jump VM, the proxy containers, the hub VNet,"
    warn "the Key Vaults, the managed identity, and the storage account."
    warn "The storage account holds every session recording in container ${LOG_CONTAINER}."
    warn "Copy out any recordings you need before you continue."
    read -erp "Type the resource group name to confirm ($RG): " typed_rg
    if [[ "$typed_rg" != "$RG" ]]; then
        info "Name did not match. Nothing was deleted."
        exit 0
    fi
else
    info "Resource group $RG not found. Only the peerings and role assignments will be checked."
fi

# -----------------------------------------------------------------------------
# 1. Target-side peering (target subscription)
# -----------------------------------------------------------------------------
TARGET_SUB="$(get_cfg TARGET_SUBSCRIPTION_ID)"
TARGET_VNET_NAME="$(get_cfg TARGET_VNET_NAME)"
TARGET_VNET_RG="$(get_cfg TARGET_VNET_RG)"

if [[ -n "$TARGET_SUB" && -n "$TARGET_VNET_NAME" && -n "$TARGET_VNET_RG" ]]; then
    if az network vnet peering show --subscription "$TARGET_SUB" \
        --resource-group "$TARGET_VNET_RG" --vnet-name "$TARGET_VNET_NAME" \
        --name "$PEERING_TARGET_SIDE" >/dev/null 2>&1; then
        az network vnet peering delete --subscription "$TARGET_SUB" \
            --resource-group "$TARGET_VNET_RG" --vnet-name "$TARGET_VNET_NAME" \
            --name "$PEERING_TARGET_SIDE" --only-show-errors
        ok "Target peering deleted: $PEERING_TARGET_SIDE on $TARGET_VNET_NAME"
    else
        info "No target peering named $PEERING_TARGET_SIDE on $TARGET_VNET_NAME"
    fi
else
    warn "No target VNet in the state file. If $PEERING_TARGET_SIDE exists in your target VNet, delete it there."
fi

# -----------------------------------------------------------------------------
# 2. Hub-side peering. The hub VNet is ours (in the group, deleted with it) or
#    an existing VNet, where the peering must be removed explicitly.
# -----------------------------------------------------------------------------
delete_hub_peering() {
    local vnet_rg="$1" vnet_name="$2"
    [[ -n "$vnet_rg" && -n "$vnet_name" ]] || return 0
    if az network vnet peering show --resource-group "$vnet_rg" --vnet-name "$vnet_name" \
        --name "$PEERING_HUB_SIDE" >/dev/null 2>&1; then
        az network vnet peering delete --resource-group "$vnet_rg" --vnet-name "$vnet_name" \
            --name "$PEERING_HUB_SIDE" --only-show-errors
        ok "Hub peering deleted: $PEERING_HUB_SIDE on $vnet_name"
    fi
}

delete_hub_peering "$RG" "$VNET"
delete_hub_peering "$(get_cfg EXISTING_VNET_RG)" "$(get_cfg EXISTING_VNET_NAME)"

# Bulk onboard names the hub peering cdx-{prefix}-<first 10 hex of sha256(vnet id)>
# and the target peering cdx-{prefix}-to-hub. Only those names are deleted.
short_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-10
    else
        printf '%s' "$1" | sha256sum | cut -c1-10
    fi
}

delete_named_peering() {
    local sub="$1" vnet_rg="$2" vnet_name="$3" peering_name="$4"
    [[ -n "$sub" && -n "$vnet_rg" && -n "$vnet_name" && -n "$peering_name" ]] || return 0
    if az network vnet peering show --subscription "$sub" --resource-group "$vnet_rg" \
        --vnet-name "$vnet_name" --name "$peering_name" >/dev/null 2>&1; then
        az network vnet peering delete --subscription "$sub" --resource-group "$vnet_rg" \
            --vnet-name "$vnet_name" --name "$peering_name" --only-show-errors \
            || { warn "Could not delete peering $peering_name on $vnet_name"; return 0; }
        ok "Peering deleted: $peering_name on $vnet_name"
    fi
}

PROGRESS_FILE="$SCRIPT_DIR/.bulk-onboard-progress.json"
if [[ -f "$PROGRESS_FILE" ]]; then
    while IFS= read -r peer_key; do
        [[ -n "$peer_key" ]] || continue
        peer_sub="${peer_key%%/*}"
        peer_rest="${peer_key#*/}"
        peer_rg="${peer_rest%%/*}"
        peer_vnet="${peer_rest#*/}"
        delete_named_peering "$peer_sub" "$peer_rg" "$peer_vnet" "$PEERING_TARGET_SIDE"
        peer_vnet_id="$(az network vnet show --subscription "$peer_sub" \
            --resource-group "$peer_rg" --name "$peer_vnet" --query id -o tsv 2>/dev/null || true)"
        if [[ -n "$peer_vnet_id" ]]; then
            peer_hub_name="cdx-${NAME_PREFIX}-$(short_hash "$peer_vnet_id")"
            delete_named_peering "$HUB_SUB" "$RG" "$VNET" "$peer_hub_name"
            delete_named_peering "$HUB_SUB" "$(get_cfg EXISTING_VNET_RG)" "$(get_cfg EXISTING_VNET_NAME)" "$peer_hub_name"
        fi
    done < <(jq -r '.peerings // {} | keys[]' "$PROGRESS_FILE")
fi

# -----------------------------------------------------------------------------
# 3. AcrPull on the registry. The registry may be the Cloudanix registry in
#    another subscription, so the group delete does not remove this grant.
#    The principal is read from our own identity before the group is deleted.
# -----------------------------------------------------------------------------
ACR_ID="$(get_cfg ACR_RESOURCE_ID)"
if [[ -n "$ACR_ID" ]] && az identity show --resource-group "$RG" --name "$IDENTITY" >/dev/null 2>&1; then
    PRINCIPAL_ID="$(az identity show --resource-group "$RG" --name "$IDENTITY" --query principalId -o tsv)"
    if az role assignment delete --assignee-object-id "$PRINCIPAL_ID" \
        --role AcrPull --scope "$ACR_ID" --only-show-errors >/dev/null 2>&1; then
        ok "AcrPull removed from the proxy identity on the registry"
    else
        warn "Could not remove AcrPull on $ACR_ID. Remove it with: az role assignment delete --assignee-object-id $PRINCIPAL_ID --role AcrPull --scope $ACR_ID"
    fi
fi

# -----------------------------------------------------------------------------
# 4. Resource group
# -----------------------------------------------------------------------------
if [[ "$(az group exists --name "$RG")" == "true" ]]; then
    info "Deleting $RG. This waits until Azure finishes."
    az group delete --name "$RG" --yes --only-show-errors
    ok "Resource group deleted: $RG"
fi

# -----------------------------------------------------------------------------
# 5. State file
# -----------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    ok "State file removed"
fi
if [[ -f "${PROGRESS_FILE:-}" ]]; then
    rm -f "$PROGRESS_FILE"
    ok "Bulk onboard progress file removed"
fi

echo ""
ok "Cleanup complete."
echo ""
warn "Not removed automatically. Do these by hand if you want them gone:"
warn "  • AllowCdxProxySsh on the target VM's network security group (inbound TCP 22 from the proxy subnet)."
warn "    az network nsg rule delete --subscription <target-sub> -g <nsg-rg> --nsg-name <nsg> -n AllowCdxProxySsh"
warn "  • AllowOperatorSSH on a customer's network security group, if you used an existing VNet."
warn "    az network nsg rule delete -g <nsg-rg> --nsg-name <nsg> -n AllowOperatorSSH"
warn "  • Key Vaults ${NAME_PREFIX}-jitenv-kv and ${NAME_PREFIX}-jitkeys-kv are in soft-delete. Their names stay reserved until the retention ends, or until you purge them."
warn "  • Custom roles CDX JIT VM Read Access and CDX JIT VM SSH Access are tenant-wide. Other hubs may use them. Delete them only after no assignments remain."
warn "  • Proxy images copied into your registry are not removed."
warn "  • The target VM itself is not touched."
