#!/usr/bin/env bash
# Creates the hub VNet (public spoke) and a jump VM with AAD SSH login.
#   1. Creates a Resource Group
#   2. Creates a VNet with a VM subnet
#   3. Creates an NSG allowing SSH only from your VPN IP
#   4. Creates a jump VM with system-assigned managed identity
#   5. Enables AAD SSH login extension on the VM
set -euo pipefail

###############################################################################
# Fixed values (same for all customers)
###############################################################################
RG="cdx-jit-k8s-hub-rg"
VNET_NAME="cdx-vnet-hub"
VM_SUBNET="cdx-snet-jumpbox"
VM_NAME="cdx-vm-jumpbox"
VM_SIZE="Standard_B2s"
ADMIN_USER="azureuser"
NSG_NAME="cdx-nsg-jumpbox"

###############################################################################
# Prompt for customer-specific inputs
###############################################################################
read -rp "Subscription ID []: " INPUT_SUBSCRIPTION_ID
SUBSCRIPTION_ID="${INPUT_SUBSCRIPTION_ID}"
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "ERROR: Subscription ID is required."
  exit 1
fi

read -rp "Location [eastus]: " INPUT_LOCATION
LOCATION="${INPUT_LOCATION:-eastus}"

read -rp "VNet address prefix [10.100.0.0/16]: " INPUT_VNET_PREFIX
VNET_PREFIX="${INPUT_VNET_PREFIX:-10.100.0.0/16}"

read -rp "VM Subnet address prefix [10.100.1.0/24]: " INPUT_VM_SUBNET_PREFIX
VM_SUBNET_PREFIX="${INPUT_VM_SUBNET_PREFIX:-10.100.1.0/24}"

read -rp "Allowed SSH source IP(s) - comma separated CIDR []: " INPUT_ALLOWED_IPS
if [[ -z "$INPUT_ALLOWED_IPS" ]]; then
  echo "ERROR: At least one allowed SSH source IP/CIDR is required (your VPN IP)."
  exit 1
fi
# Convert comma-separated to space-separated (az cli expects space-separated)
ALLOWED_IPS="${INPUT_ALLOWED_IPS//,/ }"

###############################################################################
# Set subscription context
###############################################################################
echo ""
echo "=== Setting subscription ==="
az account set --subscription "$SUBSCRIPTION_ID"

###############################################################################
# Create Resource Group
###############################################################################
echo ""
echo "=== Creating Resource Group: $RG ==="
az group create --name "$RG" --location "$LOCATION" --output none

###############################################################################
# Create VNet
###############################################################################
echo ""
echo "=== Creating VNet: $VNET_NAME ==="
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET_NAME" \
  --address-prefix "$VNET_PREFIX" \
  --location "$LOCATION" \
  --output none

###############################################################################
# Create VM Subnet
###############################################################################
echo ""
echo "=== Creating Subnet: $VM_SUBNET ==="
az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --name "$VM_SUBNET" \
  --address-prefix "$VM_SUBNET_PREFIX" \
  --output none

###############################################################################
# Create NSG and restrict SSH to VPN IP(s)
###############################################################################
echo ""
echo "=== Creating NSG: $NSG_NAME ==="
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_NAME" \
  --output none

echo "Adding SSH allow rule for: $ALLOWED_IPS"
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG_NAME" \
  --name "AllowSSH-VPN" \
  --priority 100 \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes $ALLOWED_IPS \
  --direction Inbound \
  --access Allow \
  --output none

# Attach NSG to VM subnet
az network vnet subnet update \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --name "$VM_SUBNET" \
  --network-security-group "$NSG_NAME" \
  --output none

###############################################################################
# Create Jump VM with public IP and system-assigned identity
###############################################################################
echo ""
echo "=== Creating Jump VM: $VM_NAME ==="
az vm create \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --image "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest" \
  --size "$VM_SIZE" \
  --vnet-name "$VNET_NAME" \
  --subnet "$VM_SUBNET" \
  --admin-username "$ADMIN_USER" \
  --assign-identity \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --tags owner=cloudanix service=jump-box purpose=cdx-jit-k8s \
  --output none

###############################################################################
# Enable AAD SSH Login extension
###############################################################################
echo ""
echo "=== Enabling AAD SSH Login on VM ==="
az vm extension set \
  --publisher Microsoft.Azure.ActiveDirectory \
  --name AADSSHLoginForLinux \
  --resource-group "$RG" \
  --vm-name "$VM_NAME" \
  --output none

###############################################################################
# Output summary
###############################################################################
VM_PUBLIC_IP=$(az vm list-ip-addresses \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" \
  -o tsv)

VM_ID=$(az vm show \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --query id -o tsv)

echo ""
echo "=== Done ==="
echo "Resource Group : $RG"
echo "VNet           : $VNET_NAME ($VNET_PREFIX)"
echo "VM Subnet      : $VM_SUBNET ($VM_SUBNET_PREFIX)"
echo "Jump VM        : $VM_NAME"
echo "VM Public IP   : $VM_PUBLIC_IP"
echo "VM Resource ID : $VM_ID"
echo "SSH restricted : $ALLOWED_IPS"
echo ""
echo "Test AAD SSH:"
echo "  az ssh vm -g $RG -n $VM_NAME"
echo ""