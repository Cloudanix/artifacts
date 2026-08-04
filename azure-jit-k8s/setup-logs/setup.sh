#!/bin/bash
# setup.sh - Set up AKS audit log pipeline using Azure Function App
#
# Creates:
#   1. Storage account (subscription-level, if not exists)
#   2. Event Hub namespace + hub per region (if not exists)
#   3. Diagnostic settings on each AKS cluster for kube-audit-admin logs
#   4. Function App (Consumption plan, Python) per region that:
#      - Triggers on Event Hub events (real-time, batch up to 5000)
#      - Filters out aksService events
#      - Groups events by blob path
#      - Batch writes to blob storage at:
#        aks-audit-logs/{cluster}/YYYY/MM/DD/{username}/{HH}.json
#
# Usage:
#   ./setup-functionapp.sh --clusters "cluster1,cluster2,cluster3" --region "eastus2"
#
# Requirements:
#   - Azure CLI logged in with sufficient permissions

set -euo pipefail

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
CLUSTERS=""
REGION=""
SUBSCRIPTION=""
FUNC_PACKAGE_URL=""
CDX_LEVEL_LOGGING="false"
CDX_ENDPOINT="https://api.cloudanix.com/v1/aks-audit-logs"
CDX_AUTH_TOKEN=""
CDX_DC=""

usage() {
  echo "Usage: $0 --clusters <cluster-names> --region <azure-region> --package-url <url> [--subscription <id>] [--cdx-level-logging <true|false>] [--cdx-endpoint <url>]"
  echo ""
  echo "  --clusters            Comma-separated list of AKS cluster names"
  echo "  --region              Azure region (e.g. eastus, eastus2)"
  echo "  --package-url         Signed URL to the function app zip package"
  echo "  --subscription        Azure subscription ID"
  echo "  --cdx-level-logging   (Optional) Enable Cloudanix level logging (default: false)"
  echo "  --cdx-endpoint        (Optional) Cloudanix API endpoint URL (overrides default)"
  echo "  --cdx-auth-token      (Optional) CDX token"
  echo "  --dc                  (Optional) Cloudanix data center (US, IN, MC1, EW1)"
  echo ""
  echo "Example:"
  echo "  $0 --clusters \"aks-prod-1\" --region \"eastus\" --package-url \"https://store.blob.core.windows.net/...?sig=...\""
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clusters)            CLUSTERS="$2"; shift 2 ;;
    --region)              REGION="$2"; shift 2 ;;
    --subscription)        SUBSCRIPTION="$2"; shift 2 ;;
    --package-url)         FUNC_PACKAGE_URL="$2"; shift 2 ;;
    --cdx-level-logging)   CDX_LEVEL_LOGGING="$2"; shift 2 ;;
    --cdx-endpoint)        CDX_ENDPOINT="$2"; shift 2 ;;
    --cdx-auth-token)      CDX_AUTH_TOKEN="$2"; shift 2 ;;
    --dc)                  CDX_DC="$2"; shift 2 ;;
    -h|--help)             usage ;;
    *)                     echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$CLUSTERS" || -z "$REGION" || -z "$FUNC_PACKAGE_URL" || -z "$SUBSCRIPTION" ]]; then
  echo "Error: --clusters, --region, --package-url, and --subscription are required."
  usage
fi

# Validate CDX auth token and dc when logging is enabled
if [[ "$CDX_LEVEL_LOGGING" == "true" && -z "$CDX_AUTH_TOKEN" ]]; then
  echo "Error: --cdx-auth-token is required when --cdx-level-logging is true."
  usage
fi

if [[ "$CDX_LEVEL_LOGGING" == "true" && -z "$CDX_DC" ]]; then
  echo "Error: --dc is required when --cdx-level-logging is true. Valid values: US, IN, MC1, EW1"
  usage
fi

# Set subscription
echo "Setting subscription: $SUBSCRIPTION"
az account set --subscription "$SUBSCRIPTION"

# Clear default resource group to avoid az commands defaulting to wrong RG
DEFAULT_RG=$(az config get defaults.group --query "value" -o tsv 2>/dev/null || echo "")
if [[ -n "$DEFAULT_RG" ]]; then
  echo "Clearing default resource group ($DEFAULT_RG) to avoid conflicts..."
  az config unset defaults.group 2>/dev/null || true
fi

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

# Naming conventions (storage account names: max 24 chars, globally unique, lowercase alphanumeric)
SHORT_SUB_ID=$(echo "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-11)
STORAGE_ACCOUNT_NAME="cdxaksjitlogs${SHORT_SUB_ID}"
STORAGE_RG="cdx-aks-jit-audit-infra"
STORAGE_CONTAINER="aks-audit-logs"

EVENTHUB_NS_NAME="cdx-aks-jit-ehns-${REGION}"
EVENTHUB_NAME="cdx-aks-jit-eh-${REGION}"
EVENTHUB_RG="cdx-aks-jit-rg-${REGION}"
EVENTHUB_SKU="Standard"
EVENTHUB_PARTITIONS=4
EVENTHUB_RETENTION=1  # days

FUNC_APP_NAME="cdx-aks-jit-func-${REGION}"
FUNC_STORAGE_NAME="cdxaksjitfunc${REGION//[^a-z0-9]/}"
FUNC_STORAGE_NAME=$(echo "$FUNC_STORAGE_NAME" | cut -c1-24)
FUNC_PLAN_NAME="cdx-aks-jit-plan-${REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "AKS Audit Log Pipeline Setup (Function App)"
echo "=============================================="
echo "Subscription:   $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "Region:         $REGION"
echo "Clusters:       $CLUSTERS"
echo "=============================================="

# --------------------------------------------------------------------------
# Step 1: Create resource group for shared infrastructure
# --------------------------------------------------------------------------
echo ""
echo "[1/6] Creating shared infrastructure resource group..."
az group create \
  --name "$EVENTHUB_RG" \
  --location "$REGION" \
  --output none 2>/dev/null || true
echo "  ✓ Resource group: $EVENTHUB_RG"

# --------------------------------------------------------------------------
# Step 2: Create storage account (subscription-level, if not exists)
# --------------------------------------------------------------------------
echo ""
echo "[2/6] Creating storage account..."

STORAGE_EXISTS=$(az storage account check-name --name "$STORAGE_ACCOUNT_NAME" --query "nameAvailable" -o tsv)
if [[ "$STORAGE_EXISTS" == "true" ]]; then
  # Create the storage resource group if it doesn't exist
  az group create \
    --name "$STORAGE_RG" \
    --location "$REGION" \
    --output none 2>/dev/null || true

  az storage account create \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$STORAGE_RG" \
    --location "$REGION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --access-tier Hot \
    --min-tls-version TLS1_2 \
    --output none
  echo "  ✓ Created storage account: $STORAGE_ACCOUNT_NAME"
else
  echo "  ✓ Storage account already exists: $STORAGE_ACCOUNT_NAME"
fi

# Create blob container
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$STORAGE_RG" \
  --query "[0].value" -o tsv)

az storage container create \
  --name "$STORAGE_CONTAINER" \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --account-key "$STORAGE_KEY" \
  --output none 2>/dev/null || true
echo "  ✓ Blob container: $STORAGE_CONTAINER"

STORAGE_CONNECTION_STRING=$(az storage account show-connection-string \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$STORAGE_RG" \
  --query connectionString -o tsv)

# --------------------------------------------------------------------------
# Step 3: Create Event Hub namespace and hub (region-level, if not exists)
# --------------------------------------------------------------------------
echo ""
echo "[3/6] Creating Event Hub namespace and hub..."

EH_NS_EXISTS=$(az eventhubs namespace show \
  --name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [[ -z "$EH_NS_EXISTS" ]]; then
  az eventhubs namespace create \
    --name "$EVENTHUB_NS_NAME" \
    --resource-group "$EVENTHUB_RG" \
    --location "$REGION" \
    --sku "$EVENTHUB_SKU" \
    --output none
  echo "  ✓ Created Event Hub namespace: $EVENTHUB_NS_NAME"
else
  echo "  ✓ Event Hub namespace already exists: $EVENTHUB_NS_NAME"
fi

# Create Event Hub
az eventhubs eventhub create \
  --name "$EVENTHUB_NAME" \
  --namespace-name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --partition-count "$EVENTHUB_PARTITIONS" \
  --cleanup-policy Delete \
  --retention-time-in-hours 24 \
  --output none 2>/dev/null || true
echo "  ✓ Event Hub: $EVENTHUB_NAME"

# Create shared access policies
az eventhubs namespace authorization-rule create \
  --name "FunctionAppListen" \
  --namespace-name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --rights Listen \
  --output none 2>/dev/null || true

EVENTHUB_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
  --name "FunctionAppListen" \
  --namespace-name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --query "primaryConnectionString" -o tsv)

# Create/update auth rule for diagnostic settings (requires Send when Event Hub name is specified)
az eventhubs namespace authorization-rule delete \
  --name "DiagnosticSend" \
  --namespace-name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --output none 2>/dev/null || true

az eventhubs namespace authorization-rule create \
  --name "DiagnosticSend" \
  --namespace-name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --rights Send \
  --output none 2>/dev/null || true

EVENTHUB_NS_ID=$(az eventhubs namespace show \
  --name "$EVENTHUB_NS_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --query "id" -o tsv)

EVENTHUB_AUTH_RULE_ID="${EVENTHUB_NS_ID}/authorizationRules/DiagnosticSend"

# --------------------------------------------------------------------------
# Step 4: For each cluster - create diagnostic settings
# --------------------------------------------------------------------------
echo ""
echo "[4/6] Configuring diagnostic settings for each cluster..."

IFS=',' read -ra CLUSTER_ARRAY <<< "$CLUSTERS"

for CLUSTER_NAME in "${CLUSTER_ARRAY[@]}"; do
  CLUSTER_NAME=$(echo "$CLUSTER_NAME" | xargs)  # trim whitespace
  echo ""
  echo "  Processing cluster: $CLUSTER_NAME"

  # Discover resource group using az resource list (works without subscription-level list permissions)
  CLUSTER_RG=$(az resource list \
    --name "$CLUSTER_NAME" \
    --resource-type "Microsoft.ContainerService/managedClusters" \
    --query "[0].resourceGroup" -o tsv 2>/dev/null)

  if [[ -z "$CLUSTER_RG" ]]; then
    # Fallback: try az aks list with JMESPath filter
    CLUSTER_RG=$(az aks list \
      --query "[?name=='${CLUSTER_NAME}'].resourceGroup | [0]" -o tsv 2>/dev/null)
  fi

  if [[ -z "$CLUSTER_RG" ]]; then
    echo "  ✗ Cluster '$CLUSTER_NAME' not found in subscription. Skipping."
    continue
  fi

  echo "    Resource group: $CLUSTER_RG"

  # Construct resource ID directly
  CLUSTER_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${CLUSTER_RG}/providers/Microsoft.ContainerService/managedClusters/${CLUSTER_NAME}"

  DIAG_SETTING_NAME="cdx-aks-jit-audit-to-eventhub"

  az monitor diagnostic-settings create \
    --name "$DIAG_SETTING_NAME" \
    --resource "$CLUSTER_ID" \
    --event-hub "$EVENTHUB_NAME" \
    --event-hub-rule "$EVENTHUB_AUTH_RULE_ID" \
    --logs '[{"category":"kube-audit-admin","enabled":true,"retentionPolicy":{"enabled":false,"days":0}}]' \
    --output none

  echo "    ✓ Diagnostic setting created: $DIAG_SETTING_NAME"
done

# --------------------------------------------------------------------------
# Step 5: Create Function App storage account (separate from audit logs storage)
# --------------------------------------------------------------------------
echo ""
echo "[5/6] Creating Function App infrastructure..."

# Function App needs its own storage account for internal use
FUNC_STORAGE_EXISTS=$(az storage account check-name --name "$FUNC_STORAGE_NAME" --query "nameAvailable" -o tsv)
if [[ "$FUNC_STORAGE_EXISTS" == "true" ]]; then
  az storage account create \
    --name "$FUNC_STORAGE_NAME" \
    --resource-group "$EVENTHUB_RG" \
    --location "$REGION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --output none
  echo "  ✓ Created Function App storage: $FUNC_STORAGE_NAME"
else
  echo "  ✓ Function App storage already exists: $FUNC_STORAGE_NAME"
fi

# --------------------------------------------------------------------------
# Step 6: Create and deploy Function App
# --------------------------------------------------------------------------
echo ""
echo "[6/6] Creating and deploying Function App..."

# Create Consumption plan Function App
FUNC_EXISTS=$(az functionapp show \
  --name "$FUNC_APP_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [[ -z "$FUNC_EXISTS" ]]; then
  az functionapp create \
    --name "$FUNC_APP_NAME" \
    --resource-group "$EVENTHUB_RG" \
    --storage-account "$FUNC_STORAGE_NAME" \
    --consumption-plan-location "$REGION" \
    --runtime python \
    --runtime-version 3.11 \
    --functions-version 4 \
    --os-type Linux \
    --output none
  echo "  ✓ Created Function App: $FUNC_APP_NAME"
else
  echo "  ✓ Function App already exists: $FUNC_APP_NAME"
fi

# Configure app settings
echo "  Configuring app settings..."
# Get Function App storage connection string (for internal use: checkpoints, triggers)
FUNC_STORAGE_CONN=$(az storage account show-connection-string \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --query connectionString -o tsv)

az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --settings \
    "EventHubConnection=${EVENTHUB_CONNECTION_STRING}" \
    "AzureWebJobsStorage=${FUNC_STORAGE_CONN}" \
    "AUDIT_STORAGE_CONNECTION=${STORAGE_CONNECTION_STRING}" \
    "STORAGE_CONTAINER=${STORAGE_CONTAINER}" \
    "EVENT_HUB_NAME=${EVENTHUB_NAME}" \
    "CDX_LEVEL_LOGGING=${CDX_LEVEL_LOGGING}" \
    "CDX_ENDPOINT=${CDX_ENDPOINT}" \
    "CDX_AUTH_TOKEN=${CDX_AUTH_TOKEN}" \
    "CDX_DC=${CDX_DC}" \
    "AzureWebJobsFeatureFlags=EnableWorkerIndexing" \
  --output none

echo "  ✓ App settings configured"

# Deploy the function code from pre-signed package URL
echo "  Deploying function code from package URL..."

# Set WEBSITE_RUN_FROM_PACKAGE to the signed URL
az functionapp config appsettings set \
  --name "$FUNC_APP_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --settings "WEBSITE_RUN_FROM_PACKAGE=${FUNC_PACKAGE_URL}" \
  --output none

# Restart to pick up new package
az functionapp restart \
  --name "$FUNC_APP_NAME" \
  --resource-group "$EVENTHUB_RG" \
  --output none 2>/dev/null || true

echo "  ✓ Function App configured to run from package URL"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Setup Complete"
echo "=============================================="
echo ""
echo "Infrastructure (shared):"
echo "  Resource Group:      $EVENTHUB_RG"
echo "  Storage Account:     $STORAGE_ACCOUNT_NAME (audit logs)"
echo "  Func Storage:        $FUNC_STORAGE_NAME (function internals)"
echo "  Event Hub Namespace: $EVENTHUB_NS_NAME"
echo "  Event Hub:           $EVENTHUB_NAME"
echo "  Function App:        $FUNC_APP_NAME"
echo ""
echo "Per-cluster:"
for CLUSTER_NAME in "${CLUSTER_ARRAY[@]}"; do
  CLUSTER_NAME=$(echo "$CLUSTER_NAME" | xargs)
  echo "  ${CLUSTER_NAME}: Diagnostic setting → $EVENTHUB_NAME"
done
echo ""
echo "Blob path structure:"
echo "  ${STORAGE_CONTAINER}/{cluster}/YYYY/MM/DD/{username}/{HH}.json"
echo ""
