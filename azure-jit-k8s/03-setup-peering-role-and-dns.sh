#!/usr/bin/env bash
set -euo pipefail


# Prompt for inputs (with defaults)

echo "=== Hub VNet Details (where the jump VM lives) ==="
read -rp "Hub Subscription ID []: " INPUT_HUB_SUB
HUB_SUB="${INPUT_HUB_SUB}"
if [[ -z "$HUB_SUB" ]]; then
  echo "ERROR: Hub Subscription ID is required."
  exit 1
fi

read -rp "Hub Resource Group [cdx-jit-k8s-hub-rg]: " INPUT_HUB_RG
HUB_RG="${INPUT_HUB_RG:-cdx-jit-k8s-hub-rg}"

read -rp "Hub VNet name [cdx-vnet-hub]: " INPUT_HUB_VNET
HUB_VNET="${INPUT_HUB_VNET:-cdx-vnet-hub}"

echo ""
echo "=== AKS Spoke VNet Details (where the private AKS cluster lives) ==="
read -rp "AKS Subscription ID [$HUB_SUB]: " INPUT_AKS_SUB
AKS_SUB="${INPUT_AKS_SUB:-$HUB_SUB}"

read -rp "AKS Resource Group []: " INPUT_AKS_RG
AKS_RG="${INPUT_AKS_RG}"
if [[ -z "$AKS_RG" ]]; then
  echo "ERROR: AKS Resource Group is required."
  exit 1
fi

read -rp "AKS VNet name []: " INPUT_AKS_VNET
AKS_VNET="${INPUT_AKS_VNET}"
if [[ -z "$AKS_VNET" ]]; then
  echo "ERROR: AKS VNet name is required."
  exit 1
fi

read -rp "AKS Cluster name []: " INPUT_AKS_NAME
AKS_NAME="${INPUT_AKS_NAME}"
if [[ -z "$AKS_NAME" ]]; then
  echo "ERROR: AKS Cluster name is required."
  exit 1
fi

read -rp "Peering name hub->aks [peer-hub-to-aks]: " INPUT_PEER_HUB_TO_AKS
PEER_HUB_TO_AKS="${INPUT_PEER_HUB_TO_AKS:-peer-hub-to-aks}"

read -rp "Peering name aks->hub [peer-aks-to-hub]: " INPUT_PEER_AKS_TO_HUB
PEER_AKS_TO_HUB="${INPUT_PEER_AKS_TO_HUB:-peer-aks-to-hub}"

read -rp "DNS link name [link-aks-dns-to-hub]: " INPUT_DNS_LINK_NAME
DNS_LINK_NAME="${INPUT_DNS_LINK_NAME:-link-aks-dns-to-hub}"


# Determine if cross-subscription

CROSS_SUB=false
if [[ "$HUB_SUB" != "$AKS_SUB" ]]; then
  CROSS_SUB=true
  echo ""
  echo "NOTE: Cross-subscription peering detected."
  echo "      Ensure you have Network Contributor on both subscriptions."
fi


# Ensure CDX K8s Read Access role covers AKS subscription
# (Role names are unique per tenant, so we add AKS sub to AssignableScopes)

echo ""
echo "=== Checking 'CDX K8s Read Access' role covers AKS subscription ==="
az account set --subscription "$HUB_SUB"

AKS_SCOPE="/subscriptions/${AKS_SUB}"
ROLE_ID=$(az role definition list --name "CDX K8s Read Access" --query "[0].name" -o tsv 2>/dev/null)

if [[ -z "$ROLE_ID" ]]; then
  echo "ERROR: Role 'CDX K8s Read Access' not found. Run 01-create-custom-roles.sh first."
  exit 1
fi

# Check if AKS subscription is already in AssignableScopes
EXISTING_SCOPES=$(az role definition list --name "CDX K8s Read Access" --query "[0].assignableScopes" -o tsv)

if echo "$EXISTING_SCOPES" | grep -qi "$AKS_SUB"; then
  echo "AKS subscription already in AssignableScopes. Skipping."
else
  echo "Adding AKS subscription to AssignableScopes..."
  # Build new scopes: existing + new AKS scope
  NEW_SCOPES=$(az role definition list --name "CDX K8s Read Access" --query "[0].assignableScopes" -o json | \
    python3 -c "import sys,json; scopes=json.load(sys.stdin); scopes.append('${AKS_SCOPE}'); print(json.dumps(scopes))")

  az role definition update --role-definition "{
    \"Name\": \"CDX K8s Read Access\",
    \"AssignableScopes\": ${NEW_SCOPES}
  }" --output none
  echo "AssignableScopes updated to include AKS subscription."
fi


# Get VNet resource IDs

echo ""
echo "=== Fetching VNet resource IDs ==="

az account set --subscription "$HUB_SUB"
HUB_VNET_ID=$(az network vnet show \
  --resource-group "$HUB_RG" \
  --name "$HUB_VNET" \
  --query id -o tsv)
echo "Hub VNet ID: $HUB_VNET_ID"

az account set --subscription "$AKS_SUB"
AKS_VNET_ID=$(az network vnet show \
  --resource-group "$AKS_RG" \
  --name "$AKS_VNET" \
  --query id -o tsv)
echo "AKS VNet ID: $AKS_VNET_ID"


# Create VNet Peering: Hub -> AKS

echo ""
echo "=== Creating peering: $PEER_HUB_TO_AKS (hub -> aks) ==="
az account set --subscription "$HUB_SUB"

# Check if peering already exists
if az network vnet peering show \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET" \
  --name "$PEER_HUB_TO_AKS" &>/dev/null; then
  echo "Peering '$PEER_HUB_TO_AKS' already exists. Skipping."
else
  az network vnet peering create \
    --name "$PEER_HUB_TO_AKS" \
    --resource-group "$HUB_RG" \
    --vnet-name "$HUB_VNET" \
    --remote-vnet "$AKS_VNET_ID" \
    --allow-vnet-access \
    --allow-forwarded-traffic \
    --output none
  echo "Created."
fi


# Create VNet Peering: AKS -> Hub

echo ""
echo "=== Creating peering: $PEER_AKS_TO_HUB (aks -> hub) ==="
az account set --subscription "$AKS_SUB"

if az network vnet peering show \
  --resource-group "$AKS_RG" \
  --vnet-name "$AKS_VNET" \
  --name "$PEER_AKS_TO_HUB" &>/dev/null; then
  echo "Peering '$PEER_AKS_TO_HUB' already exists. Skipping."
else
  az network vnet peering create \
    --name "$PEER_AKS_TO_HUB" \
    --resource-group "$AKS_RG" \
    --vnet-name "$AKS_VNET" \
    --remote-vnet "$HUB_VNET_ID" \
    --allow-vnet-access \
    --allow-forwarded-traffic \
    --output none
  echo "Created."
fi


# Verify peering status

echo ""
echo "=== Verifying peering status ==="

az account set --subscription "$HUB_SUB"
echo "Hub side:"
az network vnet peering show \
  --resource-group "$HUB_RG" \
  --vnet-name "$HUB_VNET" \
  --name "$PEER_HUB_TO_AKS" \
  --query "{Name:name, State:peeringState}" \
  -o table

az account set --subscription "$AKS_SUB"
echo "AKS side:"
az network vnet peering show \
  --resource-group "$AKS_RG" \
  --vnet-name "$AKS_VNET" \
  --name "$PEER_AKS_TO_HUB" \
  --query "{Name:name, State:peeringState}" \
  -o table


# Private DNS Zone Link
# Link the AKS private DNS zone to the hub VNet so the jump VM can resolve
# the AKS private API server FQDN.

echo ""
echo "=== Setting up Private DNS Zone Link ==="

# Get the AKS node resource group (where the private DNS zone lives)
AKS_NODE_RG=$(az aks show \
  --resource-group "$AKS_RG" \
  --name "$AKS_NAME" \
  --query nodeResourceGroup -o tsv)
echo "AKS Node Resource Group: $AKS_NODE_RG"

# Find the private DNS zone (privatelink.<region>.azmk8s.io)
AKS_DNS_ZONE=$(az network private-dns zone list \
  --resource-group "$AKS_NODE_RG" \
  --query "[?contains(name, 'privatelink')].name | [0]" -o tsv)

if [[ -z "$AKS_DNS_ZONE" ]]; then
  echo "ERROR: Could not find private DNS zone in $AKS_NODE_RG."
  echo "       Ensure the AKS cluster is a private cluster."
  exit 1
fi
echo "AKS Private DNS Zone: $AKS_DNS_ZONE"

# Check if link already exists
if az network private-dns link vnet show \
  --resource-group "$AKS_NODE_RG" \
  --zone-name "$AKS_DNS_ZONE" \
  --name "$DNS_LINK_NAME" &>/dev/null; then
  echo "DNS link '$DNS_LINK_NAME' already exists. Skipping."
else
  az network private-dns link vnet create \
    --resource-group "$AKS_NODE_RG" \
    --zone-name "$AKS_DNS_ZONE" \
    --name "$DNS_LINK_NAME" \
    --virtual-network "$HUB_VNET_ID" \
    --registration-enabled false \
    --output none
  echo "DNS link created."
fi


# Summary

echo ""
echo "=== Done ==="
echo ""
echo "VNet Peering:"
echo "  Hub ($HUB_VNET) <-> AKS ($AKS_VNET)"
if [[ "$CROSS_SUB" == "true" ]]; then
  echo "  Cross-subscription: Hub=$HUB_SUB, AKS=$AKS_SUB"
fi
echo ""
echo "Private DNS Zone Link:"
echo "  Zone: $AKS_DNS_ZONE"
echo "  Linked to: $HUB_VNET (hub VNet)"
echo ""