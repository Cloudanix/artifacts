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

# cdx-sql mode (UNTESTED, written 30 Oct 2026)
# Opt-in through the environment, no prompt, so the default run is unchanged:
#   PROXY_ENGINE=cdxsql CDXSQL_REPLICAS=2 ./3.deploy-aci.sh
# See CDXSQL.md for every setting and the resources this creates.
PROXY_ENGINE="${PROXY_ENGINE:-proxysql}"
CDXSQL_REPLICAS="${CDXSQL_REPLICAS:-2}"
CDXSQL_LB_NAME="${CDXSQL_LB_NAME:-cdxsql-ilb}"
CDXSQL_LB_SUBNET_PREFIX="${CDXSQL_LB_SUBNET_PREFIX:-10.0.8.0/24}"
CDXSQL_LB_IP="${CDXSQL_LB_IP:-10.0.8.5}"
case "$PROXY_ENGINE" in
  proxysql|cdxsql) ;;
  *) echo "PROXY_ENGINE must be proxysql or cdxsql (got: $PROXY_ENGINE)"; exit 1 ;;
esac
if [ "$PROXY_ENGINE" = "cdxsql" ] && ! [[ "$CDXSQL_REPLICAS" =~ ^[1-9][0-9]*$ ]]; then
  echo "CDXSQL_REPLICAS must be a whole number >= 1 (got: $CDXSQL_REPLICAS)"; exit 1
fi

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

# cdx-sql mode (UNTESTED, written 30 Oct 2026)
# cdx-sql needs two values as secure env vars: PGPASSWORD (the Key Vault
# secret POSTGRES-PASSWORD that 2.setup-infra.sh stored) and the shared admin
# token (Key Vault secret CDXSQL-ADMIN-TOKEN, made once and reused). Reading
# them needs "Key Vault Secrets Officer" for a moment, the same pattern as
# 2.setup-infra.sh; a role the user already had is left in place.
CDXSQL_ADMIN_TOKEN=""
CDXSQL_PG_PASSWORD=""
if [ "$PROXY_ENGINE" = "cdxsql" ]; then
  echo "cdx-sql mode: reading POSTGRES-PASSWORD and CDXSQL-ADMIN-TOKEN from $KEYVAULT_NAME..."
  KV_ID=$(az keyvault show --name "$KEYVAULT_NAME" --query id -o tsv)
  CURRENT_USER=$(az ad signed-in-user show --query id -o tsv)
  KV_ROLE_ADDED=false
  if [ "$(az role assignment list --assignee "$CURRENT_USER" --role "Key Vault Secrets Officer" \
          --scope "$KV_ID" --query "length(@)" -o tsv)" = "0" ]; then
    az role assignment create --assignee "$CURRENT_USER" --role "Key Vault Secrets Officer" \
      --scope "$KV_ID" --output none
    KV_ROLE_ADDED=true
  fi
  # RBAC can take a minute or two: retry the secret that must exist.
  for i in $(seq 1 18); do
    CDXSQL_PG_PASSWORD=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" \
      --name POSTGRES-PASSWORD --query value -o tsv 2>/dev/null || true)
    [ -n "$CDXSQL_PG_PASSWORD" ] && break
    echo "  waiting for Key Vault access ($i/18)..."
    sleep 10
  done
  if [ -n "$CDXSQL_PG_PASSWORD" ]; then
    CDXSQL_ADMIN_TOKEN=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" \
      --name CDXSQL-ADMIN-TOKEN --query value -o tsv 2>/dev/null || true)
    if [ -z "$CDXSQL_ADMIN_TOKEN" ]; then
      CDXSQL_ADMIN_TOKEN=$(openssl rand -hex 32)
      az keyvault secret set --vault-name "$KEYVAULT_NAME" --name CDXSQL-ADMIN-TOKEN \
        --value "$CDXSQL_ADMIN_TOKEN" --output none
      echo "  created Key Vault secret CDXSQL-ADMIN-TOKEN"
    else
      echo "  reusing Key Vault secret CDXSQL-ADMIN-TOKEN"
    fi
  fi
  if [ "$KV_ROLE_ADDED" = true ]; then
    az role assignment delete --assignee "$CURRENT_USER" --role "Key Vault Secrets Officer" \
      --scope "$KV_ID" --output none 2>/dev/null || true
  fi
  if [ -z "$CDXSQL_PG_PASSWORD" ] || [ -z "$CDXSQL_ADMIN_TOKEN" ]; then
    echo " cdx-sql mode: could not read POSTGRES-PASSWORD / CDXSQL-ADMIN-TOKEN from $KEYVAULT_NAME"
    exit 1
  fi
fi

# One cdx-sql container group: same slot as ProxySQL (ports 6032/6033/6133,
# share proxysql-data at /var/lib/proxysql). Grants live in the local Postgres.
create_cdxsql_group() {
  local name=$1
  az container create \
    --resource-group "$RESOURCE_GROUP" --name "$name" \
    --image "$ACR_SERVER"/cloudanix/ecr-aws-jit-cdx-sql:latest \
    --registry-login-server "$ACR_SERVER" \
    --registry-username "$ACR_USER" \
    --registry-password "$ACR_PASS" \
    --vnet "$VNET_NAME" --subnet aci-subnet --ip-address Private \
    --ports 6032 6033 6133 --os-type Linux --cpu 0.5 --memory 1 \
    --environment-variables \
      "CDXSQL_GRANTS_DSN=postgres://pgjitdbuser@${PG_IP}:5432/jitdb?sslmode=disable" \
    --secure-environment-variables \
      "CDXSQL_ADMIN_TOKEN=$CDXSQL_ADMIN_TOKEN" \
      "PGPASSWORD=$CDXSQL_PG_PASSWORD" \
    --azure-file-volume-account-name "$SMB_STORAGE_NAME" \
    --azure-file-volume-account-key "$SMB_KEY" \
    --azure-file-volume-share-name proxysql-data \
    --azure-file-volume-mount-path /var/lib/proxysql \
    --location "$LOCATION" \
    --restart-policy Always \
    --no-wait --output none
}

# Internal Standard Load Balancer in front of the cdx-sql groups. Its frontend
# cannot be 10.0.6.5: aci-subnet is delegated to container groups and Azure
# allows nothing else in it. So the frontend sits in its own subnet
# (cdxsql-lb-subnet) and the jump box socat + proxyserver point at it.
# Arguments: the cdx-sql groups' private IPs (the pool is replaced with them).
cdxsql_lb_sync() {
  local port addrs="" n=1 ip
  if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
       --name cdxsql-lb-subnet --output none 2>/dev/null; then
    az network vnet subnet create --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
      --name cdxsql-lb-subnet --address-prefix "$CDXSQL_LB_SUBNET_PREFIX" --output none
  fi
  if ! az network lb show --resource-group "$RESOURCE_GROUP" --name "$CDXSQL_LB_NAME" --output none 2>/dev/null; then
    az network lb create --resource-group "$RESOURCE_GROUP" --name "$CDXSQL_LB_NAME" \
      --sku Standard --location "$LOCATION" \
      --vnet-name "$VNET_NAME" --subnet cdxsql-lb-subnet \
      --private-ip-address "$CDXSQL_LB_IP" \
      --frontend-ip-name cdxsql-frontend --backend-pool-name cdxsql-pool --output none
  fi
  if ! az network lb probe show --resource-group "$RESOURCE_GROUP" --lb-name "$CDXSQL_LB_NAME" \
       --name cdxsql-tcp-6133 --output none 2>/dev/null; then
    az network lb probe create --resource-group "$RESOURCE_GROUP" --lb-name "$CDXSQL_LB_NAME" \
      --name cdxsql-tcp-6133 --protocol Tcp --port 6133 --interval 5 --output none
  fi
  # Idle timeout 30 min (Azure's 4 min default would cut idle IDE sessions),
  # TCP reset so a client learns at once when the LB drops a flow.
  for port in 6032 6033 6133; do
    if ! az network lb rule show --resource-group "$RESOURCE_GROUP" --lb-name "$CDXSQL_LB_NAME" \
         --name cdxsql-$port --output none 2>/dev/null; then
      az network lb rule create --resource-group "$RESOURCE_GROUP" --lb-name "$CDXSQL_LB_NAME" \
        --name cdxsql-$port --protocol Tcp --frontend-port $port --backend-port $port \
        --frontend-ip-name cdxsql-frontend --backend-pool-name cdxsql-pool \
        --probe-name cdxsql-tcp-6133 --idle-timeout 30 --enable-tcp-reset true --output none
    fi
  done
  for ip in "$@"; do
    addrs="${addrs:+$addrs,}{name:cdxsql-$n,ip-address:$ip,subnet:aci-subnet}"
    n=$((n + 1))
  done
  az network lb address-pool update --resource-group "$RESOURCE_GROUP" --lb-name "$CDXSQL_LB_NAME" \
    --name cdxsql-pool --vnet "$VNET_NAME" --backend-addresses "[$addrs]" --output none
  echo "   $CDXSQL_LB_NAME $CDXSQL_LB_IP → $*"
}
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
# cdx-sql mode (UNTESTED, written 30 Oct 2026)
# Also delete the extra cdx-sql groups (proxysql-2, proxysql-3, ...).
if [ "$PROXY_ENGINE" = "cdxsql" ]; then
  for svc in $(az container list --resource-group "$RESOURCE_GROUP" \
                 --query "[?starts_with(name, 'proxysql-')].name" -o tsv); do
    az container delete \
      --resource-group "$RESOURCE_GROUP" --name "$svc" \
      --yes --output none 2>/dev/null &
  done
fi
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

# cdx-sql mode (UNTESTED, written 30 Oct 2026)
# The first cdx-sql group keeps the name proxysql (and so 10.0.6.5).
if [ "$PROXY_ENGINE" = "cdxsql" ]; then
  echo "cdx-sql mode: group proxysql runs cdx-sql"
  create_cdxsql_group proxysql
else
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
fi

wait_for_container proxysql
PROXYSQL_IP=$(az container show \
  --resource-group $RESOURCE_GROUP --name proxysql \
  --query "ipAddress.ip" -o tsv)

# cdx-sql mode (UNTESTED, written 30 Oct 2026)
# Put the LB in front of the first group now, so proxyserver (next step) can
# reach cdx-sql's admin API through it; the other groups join at the end.
PROXYSERVER_PROXYSQL_HOST="$PROXYSQL_IP"
PROXYSERVER_EXTRA_ARGS=()
CDXSQL_IPS=()
if [ "$PROXY_ENGINE" = "cdxsql" ]; then
  CDXSQL_IPS=("$PROXYSQL_IP")
  echo "cdx-sql mode: load balancer $CDXSQL_LB_NAME ($CDXSQL_LB_IP)"
  cdxsql_lb_sync "${CDXSQL_IPS[@]}"
  PROXYSERVER_PROXYSQL_HOST="$CDXSQL_LB_IP"
  PROXYSERVER_EXTRA_ARGS=(
    CDX_PROXY_ENGINE=cdxsql
    --secure-environment-variables "CDXSQL_ADMIN_TOKEN=$CDXSQL_ADMIN_TOKEN"
  )
fi

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
    PROXYSQL_HOST="$PROXYSERVER_PROXYSQL_HOST" \
    DAM_SERVER_HOST=$DAM_IP \
    ${PROXYSERVER_EXTRA_ARGS[@]+"${PROXYSERVER_EXTRA_ARGS[@]}"} \
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

# cdx-sql mode (UNTESTED, written 30 Oct 2026)
# Extra cdx-sql groups proxysql-2..N are created last, so every existing
# group keeps its usual IP (.4-.8); the extras take the next free ones
# (normally .9, .10, ...). The LB pool is set from the IPs Azure gave them.
if [ "$PROXY_ENGINE" = "cdxsql" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "STEP 7 (cdx-sql mode): $CDXSQL_REPLICAS cdx-sql groups behind $CDXSQL_LB_NAME"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for n in $(seq 2 "$CDXSQL_REPLICAS"); do
    create_cdxsql_group "proxysql-$n"
    wait_for_container "proxysql-$n"
    CDXSQL_IPS+=("$(az container show \
      --resource-group "$RESOURCE_GROUP" --name "proxysql-$n" \
      --query "ipAddress.ip" -o tsv)")
  done
  cdxsql_lb_sync "${CDXSQL_IPS[@]}"

  # Jump box: point the two socat forwards (6133, 6033) at the LB frontend
  # instead of 10.0.6.5. The developer's ssh -L is unchanged.
  echo "Pointing jump box socat (6133, 6033) at $CDXSQL_LB_IP..."
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$JUMPBOX_VM_NAME" \
    --command-id RunShellScript \
    --scripts "sed -i -E 's#TCP:[0-9.]+:6133\$#TCP:$CDXSQL_LB_IP:6133#; s#TCP:[0-9.]+:6033\$#TCP:$CDXSQL_LB_IP:6033#' /etc/systemd/system/socat-proxysql-psql.service /etc/systemd/system/socat-proxysql-mysql.service && systemctl daemon-reload && systemctl restart socat-proxysql-psql socat-proxysql-mysql" \
    --output none
  echo "   jump box socat → $CDXSQL_LB_IP"
fi

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
# cdx-sql mode (UNTESTED, written 30 Oct 2026)
if [ "$PROXY_ENGINE" = "cdxsql" ]; then
  echo ""
  echo "cdx-sql mode:"
  echo "  cdx-sql groups → ${CDXSQL_IPS[*]}"
  echo "  load balancer  → $CDXSQL_LB_NAME $CDXSQL_LB_IP (6032, 6033, 6133)"
  echo "  proxyserver PROXYSQL_HOST=$CDXSQL_LB_IP, CDX_PROXY_ENGINE=cdxsql"
  echo "  verify: see CDXSQL.md"
fi
echo ""