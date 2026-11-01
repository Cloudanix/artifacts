#!/usr/bin/env bash
# =============================================================================
# Step 07 — Peer the hub VNet to the target VNet
# =============================================================================
# Creates the peering from the hub side. Step 08 creates the other direction.
# The hub VNet is the one this prefix created, or, for an existing-VNet hub,
# the VNet that the proxy container is already attached to.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

require_env SUBSCRIPTION_ID NAME_PREFIX TARGET_VNET_NAME TARGET_VNET_RG TARGET_SUBSCRIPTION_ID || exit 1
[[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9]{2,11}$ ]] || {
    error "NAME_PREFIX must be 3-12 characters: lowercase letters/digits, starting with a letter"
    exit 1
}
az account set --subscription "$SUBSCRIPTION_ID"

if az network vnet show --resource-group "$RG" --name "$VNET" >/dev/null 2>&1; then
    HUB_VNET_RG="$RG"
    HUB_VNET_NAME="$VNET"
else
    SUBNET_ID="$(az container show --resource-group "$RG" --name "$ACI_VMPROXY" \
        --query "subnetIds[0].id" -o tsv)"
    [[ -n "$SUBNET_ID" ]] || {
        error "Hub VNet not found. Run a hub install (new VNet or existing VNet) for prefix $NAME_PREFIX first."
        exit 1
    }
    HUB_VNET_RG="$(echo "$SUBNET_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
    HUB_VNET_NAME="$(echo "$SUBNET_ID" | sed -n 's|.*/virtualNetworks/\([^/]*\)/.*|\1|p')"
fi

TARGET_VNET_ID="$(az network vnet show --subscription "$TARGET_SUBSCRIPTION_ID" \
    --resource-group "$TARGET_VNET_RG" --name "$TARGET_VNET_NAME" --query id -o tsv)"
[[ -n "$TARGET_VNET_ID" ]] || {
    error "Target VNet not found: $TARGET_VNET_NAME in $TARGET_VNET_RG"
    exit 1
}

PEERING="cdx-${NAME_PREFIX}-to-target"
if az network vnet peering show --resource-group "$HUB_VNET_RG" --vnet-name "$HUB_VNET_NAME" \
    --name "$PEERING" >/dev/null 2>&1; then
    ok "Hub peering exists: $PEERING"
else
    az network vnet peering create --resource-group "$HUB_VNET_RG" --vnet-name "$HUB_VNET_NAME" \
        --name "$PEERING" --remote-vnet "$TARGET_VNET_ID" \
        --allow-vnet-access true --allow-forwarded-traffic true --only-show-errors >/dev/null
    ok "Hub peering created: $PEERING"
fi

apply_asset_tags "$(az network vnet peering show --resource-group "$HUB_VNET_RG" \
    --vnet-name "$HUB_VNET_NAME" --name "$PEERING" --query id -o tsv)"
ok "Asset tags applied"

echo "OUTPUT:HUB_VNET_NAME=$HUB_VNET_NAME"
echo "OUTPUT:HUB_VNET_RG=$HUB_VNET_RG"
