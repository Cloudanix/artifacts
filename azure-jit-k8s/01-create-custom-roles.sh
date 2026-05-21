#!/usr/bin/env bash
# Roles created:
#   1. CDX VM SSH Access    – AAD SSH login to jump VMs (hub sub)
#   2. CDX VM Read Access   – Discover jump VMs, read NIC/IP (hub sub)
#   3. CDX K8s Read Access  – Read AKS cluster info, download kubeconfig (hub sub + additional AKS subs if provided)
###############################################################################
set -euo pipefail

###############################################################################
# Prompt for inputs
###############################################################################
read -rp "Hub Subscription ID (where jump VM lives) []: " INPUT_SUBSCRIPTION_ID
SUBSCRIPTION_ID="${INPUT_SUBSCRIPTION_ID}"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "ERROR: Subscription ID is required."
  exit 1
fi

read -rp "AKS Subscription IDs (comma separated, leave empty if same as hub) []: " INPUT_AKS_SUBS
AKS_SUBS="${INPUT_AKS_SUBS}"

###############################################################################
# Set subscription context
###############################################################################
echo "Setting subscription to: $SUBSCRIPTION_ID"
az account set --subscription "$SUBSCRIPTION_ID"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

###############################################################################
# Role 1: CDX VM SSH Access
###############################################################################
echo ""
echo "=== Role: CDX VM SSH Access ==="

if az role definition list --name "CDX VM SSH Access" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
  echo "Already exists. Skipping."
else
  echo "Creating..."
  cat > /tmp/cdx-vm-ssh-access.json << EOF
{
  "Name": "CDX VM SSH Access",
  "IsCustom": true,
  "Description": "AAD SSH login to specific jump VMs for K8s tunnel",
  "Actions": [],
  "NotActions": [],
  "DataActions": [
    "Microsoft.Compute/virtualMachines/login/action"
  ],
  "NotDataActions": [],
  "AssignableScopes": [
    "${SCOPE}"
  ]
}
EOF
  az role definition create --role-definition @/tmp/cdx-vm-ssh-access.json --output none
  echo "Created."
  rm -f /tmp/cdx-vm-ssh-access.json
fi

###############################################################################
# Role 2: CDX VM Read Access
###############################################################################
echo ""
echo "=== Role: CDX VM Read Access ==="

if az role definition list --name "CDX VM Read Access" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
  echo "Already exists. Skipping."
else
  echo "Creating..."
  cat > /tmp/cdx-vm-read-access.json << EOF
{
  "Name": "CDX VM Read Access",
  "IsCustom": true,
  "Description": "Read jump VM info, NICs, and public IPs for discovery",
  "Actions": [
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/instanceView/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Network/publicIPAddresses/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "${SCOPE}"
  ]
}
EOF
  az role definition create --role-definition @/tmp/cdx-vm-read-access.json --output none
  echo "Created."
  rm -f /tmp/cdx-vm-read-access.json
fi

###############################################################################
# Role 3: CDX K8s Read Access
# Build AssignableScopes: hub sub + any additional AKS subs
###############################################################################
echo ""
echo "=== Role: CDX K8s Read Access ==="

# Build scopes array
SCOPES_JSON="[\"/subscriptions/${SUBSCRIPTION_ID}\""
if [[ -n "$AKS_SUBS" ]]; then
  IFS=',' read -ra AKS_SUB_ARRAY <<< "$AKS_SUBS"
  for sub in "${AKS_SUB_ARRAY[@]}"; do
    sub=$(echo "$sub" | xargs)  # trim whitespace
    SCOPES_JSON="${SCOPES_JSON}, \"/subscriptions/${sub}\""
  done
fi
SCOPES_JSON="${SCOPES_JSON}]"

if az role definition list --name "CDX K8s Read Access" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
  echo "Already exists. Skipping."
else
  echo "Creating with AssignableScopes: $SCOPES_JSON"
  cat > /tmp/cdx-k8s-read-access.json << EOF
{
  "Name": "CDX K8s Read Access",
  "IsCustom": true,
  "Description": "Read AKS cluster info and download kubeconfig",
  "Actions": [
    "Microsoft.ContainerService/managedClusters/read",
    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": ${SCOPES_JSON}
}
EOF
  az role definition create --role-definition @/tmp/cdx-k8s-read-access.json --output none
  echo "Created."
  rm -f /tmp/cdx-k8s-read-access.json
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=== Done ==="
echo "Roles created/verified:"
echo ""
echo "  CDX VM SSH Access   – AAD SSH login to jump VMs"
echo "  CDX VM Read Access  – Discover jump VMs, NICs, public IPs"
echo "  CDX K8s Read Access – Read AKS clusters, download kubeconfig"
echo "                        AssignableScopes: $SCOPES_JSON"
echo ""