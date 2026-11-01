#!/usr/bin/env bash
# =============================================================================
# Step 01 — Network and Jump VM
# =============================================================================
# Creates the resource group, VNet with jump / ACI / target subnets, an NSG
# that allows SSH (22) only from SSH_ALLOWED_CIDRS, a static public IP, and the
# jump VM with Entra (AAD) SSH login. The jump VM is the only public endpoint.
# Idempotent: re-running updates the NSG rule and skips existing resources.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

# Resource group
if [[ "$(az group exists --name "$RG")" == "true" ]]; then
    ok "Resource group exists: $RG"
else
    az group create --name "$RG" --location "$LOCATION" --only-show-errors >/dev/null
    ok "Resource group created: $RG"
fi

# VNet and subnets
if az network vnet show --resource-group "$RG" --name "$VNET" >/dev/null 2>&1; then
    ok "VNet exists: $VNET"
else
    az network vnet create --resource-group "$RG" --name "$VNET" --location "$LOCATION" \
        --address-prefixes "$VNET_CIDR" --only-show-errors >/dev/null
    ok "VNet created: $VNET ($VNET_CIDR)"
fi

create_subnet() {
    local name="$1" prefix="$2"
    shift 2
    if az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" \
        --name "$name" >/dev/null 2>&1; then
        ok "Subnet exists: $name"
    else
        az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
            --name "$name" --address-prefixes "$prefix" "$@" --only-show-errors >/dev/null
        ok "Subnet created: $name ($prefix)"
    fi
}
create_subnet "$JUMP_SUBNET" "$JUMP_SUBNET_CIDR"
# ACI needs a dedicated subnet delegated to Container Instances.
create_subnet "$ACI_SUBNET" "$ACI_SUBNET_CIDR" --delegations Microsoft.ContainerInstance/containerGroups
create_subnet "$VM_SUBNET" "$VM_SUBNET_CIDR"

# NSG: SSH from the operator CIDRs only. Ports 2222 and 8079 are never opened;
# step 06 binds them to loopback on the jump VM.
if ! az network nsg show --resource-group "$RG" --name "$JUMP_NSG" >/dev/null 2>&1; then
    az network nsg create --resource-group "$RG" --name "$JUMP_NSG" --location "$LOCATION" \
        --only-show-errors >/dev/null
    ok "NSG created: $JUMP_NSG"
fi
mapfile -t SSH_CIDRS < <(ssh_cidrs)
# nsg rule create is an upsert, so changed SSH_ALLOWED_CIDRS apply on re-run.
az network nsg rule create --resource-group "$RG" --nsg-name "$JUMP_NSG" \
    --name AllowOperatorSSH --priority 100 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes "${SSH_CIDRS[@]}" --only-show-errors >/dev/null
ok "NSG rule set: AllowOperatorSSH (${#SSH_CIDRS[@]} CIDR(s))"
az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name "$JUMP_SUBNET" --network-security-group "$JUMP_NSG" --only-show-errors >/dev/null

# Static public IP for the jump VM
az network public-ip create --resource-group "$RG" --name "$JUMP_PIP" \
    --location "$LOCATION" --sku Standard --only-show-errors >/dev/null
ok "Public IP ready: $JUMP_PIP"

# Jump VM. Tags match the discovery tags the CLI uses to find the jump host.
if az vm show --resource-group "$RG" --name "$JUMP_VM" >/dev/null 2>&1; then
    ok "Jump VM exists: $JUMP_VM"
else
    az vm create --resource-group "$RG" --name "$JUMP_VM" --location "$LOCATION" \
        --image Ubuntu2204 --size Standard_B2s \
        --vnet-name "$VNET" --subnet "$JUMP_SUBNET" \
        --public-ip-address "$JUMP_PIP" --nsg "" \
        --admin-username "$JUMP_VM_ADMIN_USERNAME" \
        --ssh-key-values "$JUMP_VM_SSH_PUBLIC_KEY_FILE" \
        --tags "${CDX_JUMP_TAG_ARGS[@]}" \
        --only-show-errors >/dev/null
    ok "Jump VM created: $JUMP_VM"
fi

# Entra (AAD) SSH login extension, required for az ssh vm
if az vm extension show --resource-group "$RG" --vm-name "$JUMP_VM" \
    --name AADSSHLoginForLinux >/dev/null 2>&1; then
    ok "AADSSHLoginForLinux extension exists"
else
    az vm extension set --resource-group "$RG" --vm-name "$JUMP_VM" \
        --publisher Microsoft.Azure.ActiveDirectory --name AADSSHLoginForLinux \
        --only-show-errors >/dev/null
    ok "AADSSHLoginForLinux extension installed"
fi

# Operator access: log in to the jump VM, and read the resource group so the
# CLI can discover it.
JUMP_ID="$(az vm show --resource-group "$RG" --name "$JUMP_VM" --query id -o tsv)"
ensure_role "$OPERATOR_OBJECT_ID" User "Virtual Machine User Login" "$JUMP_ID"
ensure_role "$OPERATOR_OBJECT_ID" User "Reader" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG"

apply_asset_tags \
    "$(az group show --name "$RG" --query id -o tsv)" \
    "$(az network vnet show --resource-group "$RG" --name "$VNET" --query id -o tsv)" \
    "$(az network nsg show --resource-group "$RG" --name "$JUMP_NSG" --query id -o tsv)" \
    "$(az network public-ip show --resource-group "$RG" --name "$JUMP_PIP" --query id -o tsv)"
apply_jump_tags "$JUMP_ID"
apply_asset_tags \
    "$(az vm show --resource-group "$RG" --name "$JUMP_VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)" \
    "$(az vm show --resource-group "$RG" --name "$JUMP_VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv)"
ok "Asset tags applied"
