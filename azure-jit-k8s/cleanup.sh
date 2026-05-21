#!/usr/bin/env bash
set -euo pipefail

# Prompt for inputs
read -rp "Hub Subscription ID []: " INPUT_SUB
SUBSCRIPTION_ID="${INPUT_SUB}"
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "ERROR: Subscription ID is required."
  exit 1
fi

RG="cdx-jit-k8s-hub-rg"

echo ""
az account set --subscription "$SUBSCRIPTION_ID"

# Delete hub resource group
echo "=== Deleting Resource Group: $RG ==="
if az group show --name "$RG" &>/dev/null; then
  az group delete --name "$RG" --yes --no-wait
  echo "Deletion initiated (async). RG: $RG"
else
  echo "Resource group '$RG' not found. Skipping."
fi

# Optionally delete custom roles
echo ""
read -rp "Delete custom roles (CDX VM SSH Access, CDX VM Read Access, CDX K8s Read Access)? [y/N]: " DELETE_ROLES
if [[ "${DELETE_ROLES,,}" == "y" ]]; then
  echo ""
  for ROLE_NAME in "CDX VM SSH Access" "CDX VM Read Access" "CDX K8s Read Access"; do
    echo "--- Deleting role: $ROLE_NAME ---"
    if az role definition list --name "$ROLE_NAME" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
      az role definition delete --name "$ROLE_NAME" --output none 2>&1 && echo "Deleted." || echo "Failed (may have active assignments — remove them first)."
    else
      echo "Not found. Skipping."
    fi
  done
else
  echo "Skipping role deletion."
fi

echo ""
echo "=== Done ==="
