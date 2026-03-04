#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
# Load configuration
if [ ! -f ~/jit-infra.env ]; then
  echo " Configuration file ~/jit-infra.env not found"
  echo "Run ./2.setup-infra.sh first"
  exit 1
fi

source ~/jit-infra.env

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating Custom VM SSH Login Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Resource Group: $RESOURCE_GROUP"
echo "Jump Box VM:    $JUMPBOX_VM_NAME"
echo ""

# Get resource IDs
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

VM_ID=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $JUMPBOX_VM_NAME \
  --query id -o tsv)

NIC_ID=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $JUMPBOX_VM_NAME \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)

VNET_ID=$(az network nic show --ids $NIC_ID \
  --query "ipConfigurations[0].subnet.id" -o tsv | \
  sed 's|/subnets/.*||')

PIP_ID=$(az network nic show --ids $NIC_ID \
  --query "ipConfigurations[0].publicIPAddress.id" -o tsv 2>/dev/null || echo "")

SUBSCRIPTION_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

# Create role definition
cat > /tmp/jit-vm-ssh-role.json << EOF
{
  "Name": "JIT VM SSH Login",
  "Description": "Allows SSH login to JIT Jump Box VM only. No other permissions.",
  "Actions": [
    "Microsoft.Network/publicIPAddresses/read",
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/capture/action",
    "Microsoft.Compute/virtualMachines/instanceView/read",
    "Microsoft.Compute/virtualMachines/vmSizes/read",
    "Microsoft.Compute/virtualMachines/providers/Microsoft.Insights/diagnosticSettings/read",
    "Microsoft.Compute/availabilitySets/vmSizes/read",
    "Microsoft.Compute/virtualMachineScaleSets/read",
    "Microsoft.Compute/virtualMachineScaleSets/publicIPAddresses/read",
    "Microsoft.Compute/virtualMachineScaleSets/networkInterfaces/read",
    "Microsoft.Compute/virtualMachineScaleSets/providers/Microsoft.Insights/diagnosticSettings/read",
    "Microsoft.Compute/virtualMachineScaleSets/eventGridFilters/read",
    "Microsoft.Compute/virtualMachineScaleSets/extensions/read",
    "Microsoft.Compute/virtualMachineScaleSets/extensions/roles/read",
    "Microsoft.Compute/virtualMachineScaleSets/instanceView/read",
    "Microsoft.Compute/virtualMachineScaleSets/osUpgradeHistory/read",
    "Microsoft.Compute/virtualMachineScaleSets/skus/read",
    "Microsoft.Compute/virtualMachineScaleSets/rollingUpgrades/read",
    "Microsoft.Compute/virtualMachineScaleSets/providers/Microsoft.Insights/metricDefinitions/read",
    "Microsoft.Compute/virtualMachineScaleSets/vmSizes/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/diagnosticRunCommands/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/extensions/read",
    "Microsoft.Compute/virtualMachines/instanceView/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/networkInterfaces/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/networkInterfaces/ipConfigurations/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/networkInterfaces/ipConfigurations/publicIPAddresses/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/runCommands/read",
    "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/providers/Microsoft.Insights/metricDefinitions/read",
    "Microsoft.Compute/virtualMachineScaleSets/disks/beginGetAccess/action",
    "Microsoft.Compute/locations/vmSizes/read",
    "Microsoft.Compute/virtualMachines/patchAssessmentResults/latest/read",
    "Microsoft.Compute/virtualMachines/patchAssessmentResults/latest/softwarePatches/read",
    "Microsoft.Compute/virtualMachines/patchInstallationResults/read",
    "Microsoft.Compute/virtualMachines/patchInstallationResults/softwarePatches/read",
    "Microsoft.Compute/virtualMachines/providers/Microsoft.Insights/logDefinitions/read",
    "Microsoft.Compute/virtualMachines/diagnosticRunCommands/read",
    "Microsoft.Compute/virtualMachines/extensions/read",
    "Microsoft.Compute/virtualMachines/providers/Microsoft.Insights/metricDefinitions/read",
    "Microsoft.Compute/virtualMachines/runCommands/read"
  ],
  "NotActions": [],
  "DataActions": [
    "Microsoft.Compute/virtualMachines/login/action",
    "Microsoft.Compute/virtualMachines/loginAsAdmin/action",
    "Microsoft.Compute/virtualMachines/*"
  ],
  "NotDataActions": [],
  "AssignableScopes": [
    "${SUBSCRIPTION_SCOPE}"
  ]
}
EOF

# Create role
az role definition create --role-definition /tmp/jit-vm-ssh-role.json

ROLE_ID=$(az role definition list \
  --name "JIT VM SSH Login" \
  --query "[0].id" -o tsv)

echo " Custom role created: JIT VM SSH Login"
echo "   Role ID: $ROLE_ID"
echo "  VM:     $VM_ID"
echo "  VNet:   $VNET_ID"
echo "  NIC:    $NIC_ID"
if [ -n "$PIP_ID" ]; then
  echo "  PIP:    $PIP_ID"
fi
echo ""
fi