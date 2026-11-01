#!/usr/bin/env bash
# =============================================================================
# Step 01 (existing VNet) — Jump VM in a VNet the customer already has
# =============================================================================
# Does not create a VNet. The jump VM goes in EXISTING_JUMP_SUBNET. The proxy
# containers (step 05) go in EXISTING_ACI_SUBNET, which must already be
# delegated to Container Instances or be empty so this step can delegate it.
#
# If the jump subnet already has an NSG, a rule is added to that NSG.
# The subnet association is not replaced.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
require_env EXISTING_VNET_NAME EXISTING_VNET_RG EXISTING_JUMP_SUBNET EXISTING_ACI_SUBNET || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

if ! az network vnet show --resource-group "$EXISTING_VNET_RG" --name "$EXISTING_VNET_NAME" >/dev/null 2>&1; then
    error "VNet not found: $EXISTING_VNET_NAME in $EXISTING_VNET_RG"
    exit 1
fi

JUMP_SUBNET_ID="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
    --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_JUMP_SUBNET" --query id -o tsv)"
ACI_SUBNET_ID="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
    --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_ACI_SUBNET" --query id -o tsv)"
[[ -n "$JUMP_SUBNET_ID" && -n "$ACI_SUBNET_ID" ]] || {
    error "Jump or ACI subnet was not found in $EXISTING_VNET_NAME"
    exit 1
}

# Delegate the ACI subnet only when it has no delegation yet.
DELEGATED="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
    --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_ACI_SUBNET" \
    --query "delegations[?serviceName=='Microsoft.ContainerInstance/containerGroups'].serviceName | [0]" -o tsv)"
if [[ "$DELEGATED" == "Microsoft.ContainerInstance/containerGroups" ]]; then
    ok "ACI subnet already delegated"
else
    az network vnet subnet update --resource-group "$EXISTING_VNET_RG" \
        --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_ACI_SUBNET" \
        --delegations Microsoft.ContainerInstance/containerGroups --only-show-errors >/dev/null
    ok "ACI subnet delegated to Container Instances"
fi

if [[ "$(az group exists --name "$RG")" == "true" ]]; then
    ok "Resource group exists: $RG"
else
    az group create --name "$RG" --location "$LOCATION" --only-show-errors >/dev/null
    ok "Resource group created: $RG"
fi

# SSH rule on the subnet's current NSG. Create one only when the subnet has none.
CURRENT_NSG="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
    --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_JUMP_SUBNET" \
    --query "networkSecurityGroup.id" -o tsv)"
mapfile -t SSH_CIDRS < <(ssh_cidrs)
if [[ -z "$CURRENT_NSG" ]]; then
    az network nsg create --resource-group "$RG" --name "$JUMP_NSG" --location "$LOCATION" \
        --only-show-errors >/dev/null
    az network nsg rule create --resource-group "$RG" --nsg-name "$JUMP_NSG" \
        --name AllowOperatorSSH --priority 100 --direction Inbound --access Allow \
        --protocol Tcp --destination-port-ranges 22 \
        --source-address-prefixes "${SSH_CIDRS[@]}" --only-show-errors >/dev/null
    az network vnet subnet update --resource-group "$EXISTING_VNET_RG" \
        --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_JUMP_SUBNET" \
        --network-security-group "$JUMP_NSG" --only-show-errors >/dev/null
    ok "NSG created and attached: $JUMP_NSG"
else
    NSG_RG="$(echo "$CURRENT_NSG" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
    NSG_NAME="${CURRENT_NSG##*/}"
    az network nsg rule create --resource-group "$NSG_RG" --nsg-name "$NSG_NAME" \
        --name AllowOperatorSSH --priority 100 --direction Inbound --access Allow \
        --protocol Tcp --destination-port-ranges 22 \
        --source-address-prefixes "${SSH_CIDRS[@]}" --only-show-errors >/dev/null
    ok "SSH rule added to existing NSG: $NSG_NAME"
fi

az network public-ip create --resource-group "$RG" --name "$JUMP_PIP" \
    --location "$LOCATION" --sku Standard --only-show-errors >/dev/null
ok "Public IP ready: $JUMP_PIP"

if az vm show --resource-group "$RG" --name "$JUMP_VM" >/dev/null 2>&1; then
    ok "Jump VM exists: $JUMP_VM"
else
    az vm create --resource-group "$RG" --name "$JUMP_VM" --location "$LOCATION" \
        --image Ubuntu2204 --size Standard_B2s \
        --subnet "$JUMP_SUBNET_ID" \
        --public-ip-address "$JUMP_PIP" --nsg "" \
        --admin-username "$JUMP_VM_ADMIN_USERNAME" \
        --ssh-key-values "$JUMP_VM_SSH_PUBLIC_KEY_FILE" \
        --tags "${CDX_JUMP_TAG_ARGS[@]}" \
        --only-show-errors >/dev/null
    ok "Jump VM created: $JUMP_VM"
fi

if az vm extension show --resource-group "$RG" --vm-name "$JUMP_VM" \
    --name AADSSHLoginForLinux >/dev/null 2>&1; then
    ok "AADSSHLoginForLinux extension exists"
else
    az vm extension set --resource-group "$RG" --vm-name "$JUMP_VM" \
        --publisher Microsoft.Azure.ActiveDirectory --name AADSSHLoginForLinux \
        --only-show-errors >/dev/null
    ok "AADSSHLoginForLinux extension installed"
fi

JUMP_ID="$(az vm show --resource-group "$RG" --name "$JUMP_VM" --query id -o tsv)"
ensure_role "$OPERATOR_OBJECT_ID" User "Virtual Machine User Login" "$JUMP_ID"
ensure_role "$OPERATOR_OBJECT_ID" User "Reader" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG"
ensure_role "$OPERATOR_OBJECT_ID" User "CDX JIT VM SSH Access" "$JUMP_ID"
ensure_role "$OPERATOR_OBJECT_ID" User "CDX JIT VM Read Access" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG"

apply_asset_tags \
    "$(az group show --name "$RG" --query id -o tsv)" \
    "$(az network public-ip show --resource-group "$RG" --name "$JUMP_PIP" --query id -o tsv)"
# Tag the NSG only when this script created it. A customer's existing NSG is left alone.
if [[ -z "$CURRENT_NSG" ]]; then
    apply_asset_tags "$(az network nsg show --resource-group "$RG" --name "$JUMP_NSG" --query id -o tsv)"
fi
apply_jump_tags "$JUMP_ID"
apply_asset_tags \
    "$(az vm show --resource-group "$RG" --name "$JUMP_VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)" \
    "$(az vm show --resource-group "$RG" --name "$JUMP_VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv)"
ok "Asset tags applied"

echo "OUTPUT:HUB_VNET_NAME=$EXISTING_VNET_NAME"
echo "OUTPUT:HUB_VNET_RG=$EXISTING_VNET_RG"
echo "OUTPUT:ACI_SUBNET_ID=$ACI_SUBNET_ID"
