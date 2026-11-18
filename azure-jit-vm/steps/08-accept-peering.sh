#!/usr/bin/env bash
# =============================================================================
# Step 08 — Accept peering from the target VNet
# =============================================================================
# Azure peering is two records. This creates the target-side record back to
# the hub. Same-subscription and cross-subscription both work: the target
# subscription is selected for this step only.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

require_env SUBSCRIPTION_ID NAME_PREFIX TARGET_VNET_NAME TARGET_VNET_RG TARGET_SUBSCRIPTION_ID || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

if az network vnet show --resource-group "$RG" --name "$VNET" >/dev/null 2>&1; then
    HUB_VNET_ID="$(az network vnet show --resource-group "$RG" --name "$VNET" --query id -o tsv)"
else
    SUBNET_ID="$(az container show --resource-group "$RG" --name "$ACI_VMPROXY" \
        --query "subnetIds[0].id" -o tsv)"
    HUB_VNET_RG="$(echo "$SUBNET_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
    HUB_VNET_NAME="$(echo "$SUBNET_ID" | sed -n 's|.*/virtualNetworks/\([^/]*\)/.*|\1|p')"
    HUB_VNET_ID="$(az network vnet show --resource-group "$HUB_VNET_RG" --name "$HUB_VNET_NAME" --query id -o tsv)"
fi
[[ -n "$HUB_VNET_ID" ]] || { error "Hub VNet id not found for prefix $NAME_PREFIX"; exit 1; }

use_target_subscription
PEERING="cdx-${NAME_PREFIX}-to-hub"
if az network vnet peering show --resource-group "$TARGET_VNET_RG" --vnet-name "$TARGET_VNET_NAME" \
    --name "$PEERING" >/dev/null 2>&1; then
    ok "Target peering exists: $PEERING"
else
    az network vnet peering create --resource-group "$TARGET_VNET_RG" --vnet-name "$TARGET_VNET_NAME" \
        --name "$PEERING" --remote-vnet "$HUB_VNET_ID" \
        --allow-vnet-access true --allow-forwarded-traffic true --only-show-errors >/dev/null
    ok "Target peering created: $PEERING"
fi

STATE="$(az network vnet peering show --resource-group "$TARGET_VNET_RG" --vnet-name "$TARGET_VNET_NAME" \
    --name "$PEERING" --query peeringState -o tsv)"
[[ "$STATE" == "Connected" ]] || {
    error "Peering is $STATE, not Connected. Check that the address spaces do not overlap."
    exit 1
}
ok "Peering state: Connected"
# A virtual network peering has no tags property.
az account set --subscription "$SUBSCRIPTION_ID"
