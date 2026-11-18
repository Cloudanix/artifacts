#!/usr/bin/env bash
# =============================================================================
# Step 02 — Storage Account and Key Vaults
# =============================================================================
# Creates:
#   - Storage account with the sshpiper working-dir share, the recordings
#     share (mounted by all three containers), and the log blob container.
#   - Two RBAC-enabled Key Vaults: one for runtime config, one for target
#     SSH private keys.
# The deploying user gets Key Vault Secrets Officer so step 04 can write
# secrets. Idempotent.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

# Storage account (PUT, so re-running applies the same settings)
az storage account create --resource-group "$RG" --name "$STORAGE" --location "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --only-show-errors >/dev/null
ok "Storage account ready: $STORAGE"

STORAGE_KEY="$(az storage account keys list --resource-group "$RG" --account-name "$STORAGE" \
    --query '[0].value' -o tsv)"

# File shares and blob container. create is a no-op when they already exist.
az storage share create --account-name "$STORAGE" --account-key "$STORAGE_KEY" \
    --name "$WORK_SHARE" --quota 50 --only-show-errors >/dev/null
az storage share create --account-name "$STORAGE" --account-key "$STORAGE_KEY" \
    --name "$RECORDINGS_SHARE" --quota 50 --only-show-errors >/dev/null
az storage container create --account-name "$STORAGE" --account-key "$STORAGE_KEY" \
    --name "$LOG_CONTAINER" --only-show-errors >/dev/null
ok "Shares and log container ready: $WORK_SHARE, $RECORDINGS_SHARE, $LOG_CONTAINER"

# Key Vaults (RBAC authorization, not access policies)
for vault in "$KV_ENV" "$KV_KEYS"; do
    if az keyvault show --resource-group "$RG" --name "$vault" >/dev/null 2>&1; then
        ok "Key Vault exists: $vault"
    else
        az keyvault create --resource-group "$RG" --name "$vault" --location "$LOCATION" \
            --enable-rbac-authorization true --only-show-errors >/dev/null
        ok "Key Vault created: $vault"
    fi
done

# Deployer writes secrets in step 04 and target keys later. Object ID comes from
# the signed-in user, so this step must run as a user principal, not a service
# principal.
DEPLOYER_ID="$(az ad signed-in-user show --query id -o tsv)"
for vault in "$KV_ENV" "$KV_KEYS"; do
    VAULT_ID="$(az keyvault show --resource-group "$RG" --name "$vault" --query id -o tsv)"
    ensure_role "$DEPLOYER_ID" User "Key Vault Secrets Officer" "$VAULT_ID"
    apply_asset_tags "$VAULT_ID"
done
apply_asset_tags "$(az storage account show --resource-group "$RG" --name "$STORAGE" --query id -o tsv)"
ok "Asset tags applied"
