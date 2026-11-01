#!/usr/bin/env bash
# =============================================================================
# Step 05 — Private Proxy Containers
# =============================================================================
# Deploys three container groups on the private ACI subnet. None of them has a
# public IP.
#   sshpiper   port 2222  — SSH router; mounts working dir and recordings
#   vmproxy    port 8079  — control API; mounts working dir and recordings
#   logging    port 8079  — uploads session recordings to blob storage
#
# Existing container groups are left alone. To pick up a new image tag, delete
# the group and re-run this step, then run step 06 (its private IP changes).
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

if [[ -n "${EXISTING_ACI_SUBNET:-}" ]]; then
    ACI_SUBNET_ID="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
        --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_ACI_SUBNET" --query id -o tsv)"
else
    ACI_SUBNET_ID="$(az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" \
        --name "$ACI_SUBNET" --query id -o tsv)"
fi
IDENTITY_ID="$(az identity show --resource-group "$RG" --name "$IDENTITY" --query id -o tsv)"
IDENTITY_CLIENT_ID="$(az identity show --resource-group "$RG" --name "$IDENTITY" --query clientId -o tsv)"
KV_ENV_URL="https://${KV_ENV}.vault.azure.net/"
STORAGE_KEY="$(az storage account keys list --resource-group "$RG" --account-name "$STORAGE" \
    --query '[0].value' -o tsv)"

# build_manifest NAME IMAGE PORT WITH_WORKDIR
#   Emits the container group definition as JSON. jq handles all quoting.
build_manifest() {
    local name="$1" image="$2" port="$3" with_workdir="$4"
    jq -n \
        --arg name "$name" \
        --arg location "$LOCATION" \
        --arg image "$IMAGE_REGISTRY/$image:$IMAGE_TAG" \
        --arg identity "$IDENTITY_ID" \
        --arg client_id "$IDENTITY_CLIENT_ID" \
        --arg kv_env_url "$KV_ENV_URL" \
        --arg kv_keys "$KV_KEYS" \
        --arg registry "$IMAGE_REGISTRY" \
        --arg subnet "$ACI_SUBNET_ID" \
        --arg account "$STORAGE" \
        --arg account_key "$STORAGE_KEY" \
        --arg recordings "$RECORDINGS_SHARE" \
        --arg workdir "$WORK_SHARE" \
        --argjson port "$port" \
        --argjson with_workdir "$with_workdir" '
        {
          apiVersion: "2021-10-01",
          name: $name,
          location: $location,
          tags: {
            "asset-owner": "Cloudanix",
            "asset-service": "CloudSecurity",
            "asset-purpose": "Security-Monitoring"
          },
          identity: {type: "UserAssigned", userAssignedIdentities: {($identity): {}}},
          properties: {
            containers: [{
              name: $name,
              properties: {
                image: $image,
                ports: [{port: $port}],
                resources: {requests: {cpu: 0.5, memoryInGB: 1}},
                environmentVariables: [
                  {name: "AZURE_CLIENT_ID", value: $client_id},
                  {name: "AZURE_KEYVAULT_URL", value: $kv_env_url},
                  {name: "CDX_APP_ENV", value: "PRODUCTION"},
                  {name: "CDX_ENVIRONMENT", value: "PRODUCTION"},
                  {name: "CDX_VM_AZURE_KEY_VAULT_NAME", value: $kv_keys}
                ],
                volumeMounts: ([{name: "recordings", mountPath: "/tmp/recordings"}]
                  + (if $with_workdir then [{name: "workingdir", mountPath: "/tmp/sshpiper/workingdir"}] else [] end))
              }
            }],
            imageRegistryCredentials: [{server: $registry, identity: $identity}],
            ipAddress: {type: "Private", ports: [{protocol: "TCP", port: $port}]},
            osType: "Linux",
            restartPolicy: "Always",
            subnetIds: [{id: $subnet}],
            volumes: ([{name: "recordings", azureFile: {shareName: $recordings, storageAccountName: $account, storageAccountKey: $account_key}}]
              + (if $with_workdir then [{name: "workingdir", azureFile: {shareName: $workdir, storageAccountName: $account, storageAccountKey: $account_key}}] else [] end))
          }
        }'
}

# deploy_container NAME IMAGE PORT WITH_WORKDIR
deploy_container() {
    local name="$1" image="$2" port="$3" with_workdir="$4" manifest
    if az container show --resource-group "$RG" --name "$name" >/dev/null 2>&1; then
        apply_asset_tags "$(az container show --resource-group "$RG" --name "$name" --query id -o tsv)"
        ok "Container group exists, tags refreshed: $name"
        return 0
    fi
    # The manifest holds the storage key, so it lives in a 0600 temp file that
    # is removed on both success and failure.
    manifest="$(mktemp)"
    chmod 600 "$manifest"
    build_manifest "$name" "$image" "$port" "$with_workdir" > "$manifest"
    if ! az container create --resource-group "$RG" --file "$manifest" --only-show-errors >/dev/null; then
        rm -f "$manifest"
        error "Failed to create container group: $name"
        return 1
    fi
    rm -f "$manifest"
    ok "Container group created: $name"
}

deploy_container "$ACI_SSHPIPER" "$SSHPIPER_IMAGE" 2222 true
deploy_container "$ACI_VMPROXY" "$VMPROXY_IMAGE" 8079 true
deploy_container "$ACI_LOGGING" "$LOGGING_IMAGE" 8079 false

SSHPIPER_PRIVATE_IP="$(az container show --resource-group "$RG" --name "$ACI_SSHPIPER" --query ipAddress.ip -o tsv)"
VMPROXY_PRIVATE_IP="$(az container show --resource-group "$RG" --name "$ACI_VMPROXY" --query ipAddress.ip -o tsv)"
LOGGING_PRIVATE_IP="$(az container show --resource-group "$RG" --name "$ACI_LOGGING" --query ipAddress.ip -o tsv)"
ok "Private IPs: sshpiper=$SSHPIPER_PRIVATE_IP vmproxy=$VMPROXY_PRIVATE_IP logging=$LOGGING_PRIVATE_IP"

echo "OUTPUT:SSHPIPER_PRIVATE_IP=$SSHPIPER_PRIVATE_IP"
echo "OUTPUT:VMPROXY_PRIVATE_IP=$VMPROXY_PRIVATE_IP"
echo "OUTPUT:LOGGING_PRIVATE_IP=$LOGGING_PRIVATE_IP"
