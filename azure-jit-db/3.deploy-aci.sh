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
echo "JIT Database Access - ACI Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Resource Group: $RESOURCE_GROUP"
echo "ACR:            $ACR_SERVER"
echo "Managed ID:     $IDENTITY_NAME"
echo ""

# ── Load credentials ───────────────────────────────────────
echo "Loading credentials..."

SMB_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $SMB_STORAGE_NAME \
  --query "[0].value" -o tsv)

ACR_USER=$(az acr credential show --name $ACR_NAME --query username -o tsv)
ACR_PASS=$(az acr credential show --name $ACR_NAME --query "passwords[0].value" -o tsv)

KV_URL="https://${KEYVAULT_NAME}.vault.azure.net/"

echo " Credentials loaded"
echo "   Key Vault URL: $KV_URL"
echo "   SMB Storage:   $SMB_STORAGE_NAME"
echo ""

# ── Helper: poll until Running or Terminated ───────────────
wait_for_container() {
  local name=$1
  local max=${2:-30}
  echo "  Polling $name..."
  for i in $(seq 1 $max); do
    sleep 10
    STATE=$(az container show \
      --resource-group $RESOURCE_GROUP --name $name \
      --query "containers[0].instanceView.currentState.state" \
      -o tsv 2>/dev/null || echo "pending")
    
    echo "  [$i] $name: $STATE"
    
    if [ "$STATE" = "Running" ]; then
      break
    fi
    
    if [ "$STATE" = "Terminated" ]; then
      echo "   $name TERMINATED — checking logs..."
      LOGS=$(az container logs \
        --resource-group $RESOURCE_GROUP --name $name 2>/dev/null || echo "")
      if [ -n "$LOGS" ]; then
        echo "$LOGS"
      fi
      exit 1
    fi
  done
  
  IP=$(az container show \
    --resource-group $RESOURCE_GROUP --name $name \
    --query "ipAddress.ip" -o tsv 2>/dev/null || echo "no-ip")
  echo "   $name → $IP"
}

# ── STEP 1: Delete ALL containers in parallel ─────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 1: Deleting all containers..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for svc in postgresql proxysql proxyserver query-logging dam-server; do
  az container delete \
    --resource-group $RESOURCE_GROUP --name $svc \
    --yes --output none 2>/dev/null &
done
wait

DAM_IP='10.0.6.8'

echo "Waiting 90s for subnet IPs to release..."
sleep 90
echo " All deleted"

# ── STEP 2: postgresql (gets .4) ──────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 2: Deploying postgresql (→ 10.0.6.4)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az container create \
  --resource-group $RESOURCE_GROUP --name postgresql \
  --image $ACR_SERVER/cloudanix/ecr-aws-jit-postgresql:latest \
  --registry-login-server $ACR_SERVER \
  --registry-username $ACR_USER \
  --registry-password $ACR_PASS \
  --vnet $VNET_NAME --subnet aci-subnet --ip-address Private \
  --ports 5432 --os-type Linux --cpu 1 --memory 2 \
  --environment-variables \
    AZURE_CLIENT_ID=$IDENTITY_CLIENT_ID \
    AZURE_KEYVAULT_URL=$KV_URL \
    POSTGRES_DB=jitdb \
    POSTGRES_USER=pgjitdbuser \
    DAM_SERVER_HOST=$DAM_IP \
  --location $LOCATION \
  --restart-policy Always \
  --assign-identity $IDENTITY_ID \
  --no-wait --output none

wait_for_container postgresql
PG_IP=$(az container show \
  --resource-group $RESOURCE_GROUP --name postgresql \
  --query "ipAddress.ip" -o tsv)

# ── STEP 3: proxysql (gets .5) ────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 3: Deploying proxysql (→ 10.0.6.5)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az container create \
  --resource-group $RESOURCE_GROUP --name proxysql \
  --image $ACR_SERVER/cloudanix/ecr-aws-jit-proxy-sql:latest \
  --registry-login-server $ACR_SERVER \
  --registry-username $ACR_USER \
  --registry-password $ACR_PASS \
  --vnet $VNET_NAME --subnet aci-subnet --ip-address Private \
  --ports 6032 6033 6132 6133 --os-type Linux --cpu 0.5 --memory 1 \
  --environment-variables \
    AZURE_CLIENT_ID=$IDENTITY_CLIENT_ID \
    AZURE_KEYVAULT_URL=$KV_URL \
    POSTGRESQL_HOST=$PG_IP \
  --azure-file-volume-account-name $SMB_STORAGE_NAME \
  --azure-file-volume-account-key $SMB_KEY \
  --azure-file-volume-share-name proxysql-data \
  --azure-file-volume-mount-path /var/lib/proxysql \
  --location $LOCATION \
  --restart-policy Always \
  --assign-identity $IDENTITY_ID \
  --no-wait --output none

wait_for_container proxysql
PROXYSQL_IP=$(az container show \
  --resource-group $RESOURCE_GROUP --name proxysql \
  --query "ipAddress.ip" -o tsv)

# ── STEP 4: proxyserver (gets .6) ─────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 4: Deploying proxyserver (→ 10.0.6.6)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az container create \
  --resource-group $RESOURCE_GROUP --name proxyserver \
  --image $ACR_SERVER/cloudanix/ecr-aws-jit-proxy-server:latest \
  --registry-login-server $ACR_SERVER \
  --registry-username $ACR_USER \
  --registry-password $ACR_PASS \
  --vnet $VNET_NAME --subnet aci-subnet --ip-address Private \
  --ports 8079 --os-type Linux --cpu 0.5 --memory 1 \
  --environment-variables \
    AZURE_CLIENT_ID=$IDENTITY_CLIENT_ID \
    AZURE_KEYVAULT_URL=$KV_URL \
    POSTGRESQL_HOST=$PG_IP \
    PROXYSQL_HOST=$PROXYSQL_IP \
    DAM_SERVER_HOST=$DAM_IP \
  --azure-file-volume-account-name $SMB_STORAGE_NAME \
  --azure-file-volume-account-key $SMB_KEY \
  --azure-file-volume-share-name proxysql-data \
  --azure-file-volume-mount-path /var/lib/proxysql \
  --location $LOCATION \
  --restart-policy Always \
  --assign-identity $IDENTITY_ID \
  --no-wait --output none

wait_for_container proxyserver 30
PROXYSERVER_IP=$(az container show \
  --resource-group $RESOURCE_GROUP --name proxyserver \
  --query "ipAddress.ip" -o tsv)

# ── STEP 5: query-logging (gets .7) ───────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 5: Deploying query-logging (→ 10.0.6.7)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az container create \
  --resource-group $RESOURCE_GROUP --name query-logging \
  --image $ACR_SERVER/cloudanix/ecr-aws-jit-query-logging:latest \
  --registry-login-server $ACR_SERVER \
  --registry-username $ACR_USER \
  --registry-password $ACR_PASS \
  --vnet $VNET_NAME --subnet aci-subnet --ip-address Private \
  --ports 8079 --os-type Linux --cpu 0.5 --memory 1 \
  --environment-variables \
    AZURE_CLIENT_ID=$IDENTITY_CLIENT_ID \
    AZURE_KEYVAULT_URL=$KV_URL \
    POSTGRESQL_HOST=$PG_IP \
    PROXYSQL_HOST=$PROXYSQL_IP \
  --azure-file-volume-account-name $SMB_STORAGE_NAME \
  --azure-file-volume-account-key $SMB_KEY \
  --azure-file-volume-share-name proxysql-data \
  --azure-file-volume-mount-path /var/lib/proxysql \
  --location $LOCATION \
  --restart-policy Always \
  --assign-identity $IDENTITY_ID \
  --no-wait --output none

wait_for_container query-logging 30
QUERYLOG_IP=$(az container show \
  --resource-group $RESOURCE_GROUP --name query-logging \
  --query "ipAddress.ip" -o tsv)

# ── STEP 6: dam-server (gets .8) ──────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 6: Deploying dam-server (→ 10.0.6.8)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az container create \
  --resource-group $RESOURCE_GROUP --name dam-server \
  --image $ACR_SERVER/cloudanix/ecr-aws-jit-dam-server:latest \
  --registry-login-server $ACR_SERVER \
  --registry-username $ACR_USER \
  --registry-password $ACR_PASS \
  --vnet $VNET_NAME --subnet aci-subnet --ip-address Private \
  --ports 8080 --os-type Linux --cpu 0.5 --memory 1 \
  --environment-variables \
    AZURE_CLIENT_ID=$IDENTITY_CLIENT_ID \
    AZURE_KEYVAULT_URL=$KV_URL \
    POSTGRESQL_HOST=$PG_IP \
    PROXYSQL_HOST=$PROXYSQL_IP \
    PROXYSERVER_HOST=$PROXYSERVER_IP \
    DAM_SERVER_HOST=$DAM_IP \
  --azure-file-volume-account-name $SMB_STORAGE_NAME \
  --azure-file-volume-account-key $SMB_KEY \
  --azure-file-volume-share-name proxysql-data \
  --azure-file-volume-mount-path /var/lib/proxysql \
  --location $LOCATION \
  --restart-policy Always \
  --assign-identity $IDENTITY_ID \
  --no-wait --output none

wait_for_container dam-server 20
DAMSERVER_IP=$(az container show \
  --resource-group $RESOURCE_GROUP --name dam-server \
  --query "ipAddress.ip" -o tsv)

# ── Final summary ──────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DEPLOYMENT COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az container list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{Name:name, State:instanceView.state, IP:ipAddress.ip}" \
  --output table

echo ""
echo "Container IPs:"
echo "  postgresql    → $PG_IP"
echo "  proxysql      → $PROXYSQL_IP"
echo "  proxyserver   → $PROXYSERVER_IP"
echo "  query-logging → $QUERYLOG_IP"
echo "  dam-server    → $DAMSERVER_IP"
echo ""

echo "IP Stability Check:"
[ "$PG_IP"          = "10.0.6.4" ] && echo " postgresql    IP stable" || echo "⚠️  postgresql    shifted: $PG_IP (expected 10.0.6.4)"
[ "$PROXYSQL_IP"    = "10.0.6.5" ] && echo " proxysql      IP stable" || echo "⚠️  proxysql      shifted: $PROXYSQL_IP (expected 10.0.6.5)"
[ "$PROXYSERVER_IP" = "10.0.6.6" ] && echo " proxyserver   IP stable" || echo "⚠️  proxyserver   shifted: $PROXYSERVER_IP (expected 10.0.6.6)"
[ "$QUERYLOG_IP"    = "10.0.6.7" ] && echo " query-logging IP stable" || echo "⚠️  query-logging shifted: $QUERYLOG_IP (expected 10.0.6.7)"
[ "$DAMSERVER_IP"   = "10.0.6.8" ] && echo " dam-server    IP stable" || echo "⚠️  dam-server    shifted: $DAMSERVER_IP (expected 10.0.6.8)"
echo ""