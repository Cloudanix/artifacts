#!/usr/bin/env bash
# =============================================================================
# Step 03 — Managed Identity and Role Assignments
# =============================================================================
# One user-assigned identity runs all three containers. It gets only:
#   - Key Vault Secrets User on both vaults (read runtime config and SSH keys)
#   - Storage Blob Data Contributor on the storage account (upload recordings)
#   - AcrPull on the image registry
# Idempotent.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

if az identity show --resource-group "$RG" --name "$IDENTITY" >/dev/null 2>&1; then
    ok "Managed identity exists: $IDENTITY"
else
    az identity create --resource-group "$RG" --name "$IDENTITY" --location "$LOCATION" \
        --only-show-errors >/dev/null
    ok "Managed identity created: $IDENTITY"
fi

PRINCIPAL_ID="$(az identity show --resource-group "$RG" --name "$IDENTITY" --query principalId -o tsv)"
STORAGE_ID="$(az storage account show --resource-group "$RG" --name "$STORAGE" --query id -o tsv)"
ACR_ID="$ACR_RESOURCE_ID"

for vault in "$KV_ENV" "$KV_KEYS"; do
    VAULT_ID="$(az keyvault show --resource-group "$RG" --name "$vault" --query id -o tsv)"
    ensure_role "$PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets User" "$VAULT_ID"
done
ensure_role "$PRINCIPAL_ID" ServicePrincipal "Storage Blob Data Contributor" "$STORAGE_ID"
ensure_role "$PRINCIPAL_ID" ServicePrincipal "AcrPull" "$ACR_ID"
apply_asset_tags "$(az identity show --resource-group "$RG" --name "$IDENTITY" --query id -o tsv)"
ok "Asset tags applied"
