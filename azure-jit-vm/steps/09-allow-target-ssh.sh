#!/usr/bin/env bash
# =============================================================================
# Step 09 — Allow the proxy subnet to SSH to the target
# =============================================================================
# Adds TCP 22 from the proxy subnet CIDR on the target NIC's NSG, or on the
# target subnet NSG when the NIC has none. If neither has an NSG, the step
# stops with the CIDR to add by hand. It does not create an NSG on a NIC
# that was previously open.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_target || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

if [[ -n "${EXISTING_ACI_SUBNET:-}" && -n "${EXISTING_VNET_NAME:-}" ]]; then
    PROXY_CIDR="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
        --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_ACI_SUBNET" \
        --query "addressPrefix" -o tsv)"
else
    SUBNET_ID="$(az container show --resource-group "$RG" --name "$ACI_VMPROXY" \
        --query "subnetIds[0].id" -o tsv 2>/dev/null || true)"
    if [[ -n "$SUBNET_ID" ]]; then
        HUB_VNET_RG="$(echo "$SUBNET_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
        HUB_VNET_NAME="$(echo "$SUBNET_ID" | sed -n 's|.*/virtualNetworks/\([^/]*\)/.*|\1|p')"
        HUB_SUBNET_NAME="${SUBNET_ID##*/}"
        PROXY_CIDR="$(az network vnet subnet show --resource-group "$HUB_VNET_RG" \
            --vnet-name "$HUB_VNET_NAME" --name "$HUB_SUBNET_NAME" --query "addressPrefix" -o tsv)"
    else
        PROXY_CIDR="$ACI_SUBNET_CIDR"
    fi
fi
[[ -n "$PROXY_CIDR" ]] || { error "Could not resolve the proxy subnet CIDR"; exit 1; }

use_target_subscription
NIC_ID="$(az vm show --resource-group "$TARGET_VM_RG" --name "$TARGET_VM_NAME" \
    --query "networkProfile.networkInterfaces[0].id" -o tsv)"
[[ -n "$NIC_ID" ]] || { error "Target VM not found: $TARGET_VM_NAME in $TARGET_VM_RG"; exit 1; }

NSG_ID="$(az network nic show --ids "$NIC_ID" --query "networkSecurityGroup.id" -o tsv)"
if [[ -z "$NSG_ID" ]]; then
    SUBNET_ID="$(az network nic show --ids "$NIC_ID" --query "ipConfigurations[0].subnet.id" -o tsv)"
    NSG_ID="$(az network vnet subnet show --ids "$SUBNET_ID" --query "networkSecurityGroup.id" -o tsv)"
fi

if [[ -z "$NSG_ID" ]]; then
    warn "Target VM has no NSG. Allow TCP 22 from $PROXY_CIDR yourself, then re-run."
    az account set --subscription "$SUBSCRIPTION_ID"
    exit 1
fi

NSG_RG="$(echo "$NSG_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
NSG_NAME="${NSG_ID##*/}"
az network nsg rule create --resource-group "$NSG_RG" --nsg-name "$NSG_NAME" \
    --name AllowCdxProxySsh --priority 1000 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes "$PROXY_CIDR" --only-show-errors >/dev/null
ok "NSG $NSG_NAME allows TCP 22 from $PROXY_CIDR"
az account set --subscription "$SUBSCRIPTION_ID"

echo "OUTPUT:PROXY_CIDR=$PROXY_CIDR"
