#!/bin/bash
# cleanup.sh - Remove AKS audit log pipeline resources (Function App)
#
# By default, only removes diagnostic settings from each cluster.
#
# With --full-cleanup, also removes:
#   - Function App
#   - Function App storage account
#   - Event Hub namespace and hub
#   - Region resource group
#
# With --include-storage, also removes:
#   - Shared audit logs storage account (cdxaksjitlogs)
#
# Usage:
#   ./cleanup-functionapp.sh --clusters "cluster1,cluster2" --region "eastus2"
#   ./cleanup-functionapp.sh --clusters "cluster1,cluster2" --region "eastus2" --full-cleanup
#   ./cleanup-functionapp.sh --clusters "cluster1,cluster2" --region "eastus2" --full-cleanup --include-storage
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
FULL_CLEANUP=false
INCLUDE_STORAGE=false

usage() {
  echo "Usage: $0 --clusters <comma-separated-cluster-names> --region <azure-region> --subscription <id> [--full-cleanup] [--include-storage]"
  echo ""
  echo "Options:"
  echo "  --clusters         Comma-separated list of AKS cluster names"
  echo "  --region           Azure region"
  echo "  --subscription     Azure subscription ID"
  echo "  --full-cleanup     Also delete Function App, Event Hub, and resource group"
  echo "  --include-storage  Also delete the shared storage account (cdxaksjitlogs)"
  echo ""
  echo "Example:"
  echo "  $0 --clusters \"aks-prod-1,aks-staging-2\" --region \"eastus\" --full-cleanup"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clusters)         CLUSTERS="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --subscription)     SUBSCRIPTION="$2"; shift 2 ;;
    --full-cleanup)     FULL_CLEANUP=true; shift ;;
    --include-storage)  INCLUDE_STORAGE=true; shift ;;
    -h|--help)          usage ;;
    *)                  echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$CLUSTERS" || -z "$REGION" || -z "$SUBSCRIPTION" ]]; then
  echo "Error: --clusters, --region, and --subscription are required."
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
# Configuration (must match setup-functionapp.sh)
# --------------------------------------------------------------------------
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

SHORT_SUB_ID=$(echo "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-11)
STORAGE_ACCOUNT_NAME="cdxaksjitlogs${SHORT_SUB_ID}"
STORAGE_RG="cdx-aks-jit-audit-infra"

EVENTHUB_NS_NAME="cdx-aks-jit-ehns-${REGION}"
EVENTHUB_NAME="cdx-aks-jit-eh-${REGION}"
EVENTHUB_RG="cdx-aks-jit-rg-${REGION}"

FUNC_APP_NAME="cdx-aks-jit-func-${REGION}"
FUNC_STORAGE_NAME="cdxaksjitfunc${REGION//[^a-z0-9]/}"
FUNC_STORAGE_NAME=$(echo "$FUNC_STORAGE_NAME" | cut -c1-24)

DIAG_SETTING_NAME="cdx-aks-jit-audit-to-eventhub"

echo "=============================================="
echo "AKS Audit Log Pipeline Cleanup (Function App)"
echo "=============================================="
echo "Subscription:   $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "Region:         $REGION"
echo "Clusters:       $CLUSTERS"
echo "Full cleanup:   $FULL_CLEANUP"
echo "Delete storage: $INCLUDE_STORAGE"
echo "=============================================="
echo ""

# --------------------------------------------------------------------------
# Step 1: Remove diagnostic settings from each cluster
# --------------------------------------------------------------------------
echo "[1/3] Removing diagnostic settings from clusters..."

IFS=',' read -ra CLUSTER_ARRAY <<< "$CLUSTERS"

for CLUSTER_NAME in "${CLUSTER_ARRAY[@]}"; do
  CLUSTER_NAME=$(echo "$CLUSTER_NAME" | xargs)
  echo ""
  echo "  Processing cluster: $CLUSTER_NAME"

  CLUSTER_RG=$(az aks list \
    --query "[?name=='${CLUSTER_NAME}'].resourceGroup | [0]" -o tsv 2>/dev/null)

  if [[ -z "$CLUSTER_RG" ]]; then
    echo "  ✗ Cluster '$CLUSTER_NAME' not found in subscription. Skipping."
    continue
  fi

  CLUSTER_ID=$(az aks show \
    --name "$CLUSTER_NAME" \
    --resource-group "$CLUSTER_RG" \
    --query "id" -o tsv)

  az monitor diagnostic-settings delete \
    --name "$DIAG_SETTING_NAME" \
    --resource "$CLUSTER_ID" \
    --output none 2>/dev/null || true

  echo "    ✓ Removed diagnostic setting: $DIAG_SETTING_NAME"
done

# --------------------------------------------------------------------------
# Step 2: Delete Function App, Function storage, Event Hub, resource group
#         (only with --full-cleanup)
# --------------------------------------------------------------------------
if [[ "$FULL_CLEANUP" == "true" ]]; then

  echo ""
  echo "[2/3] Deleting Function App..."

  az functionapp delete \
    --name "$FUNC_APP_NAME" \
    --resource-group "$EVENTHUB_RG" \
    --output none 2>/dev/null || true
  echo "  ✓ Deleted Function App: $FUNC_APP_NAME"

  echo ""
  echo "  Deleting Function App storage account..."
  az storage account delete \
    --name "$FUNC_STORAGE_NAME" \
    --resource-group "$EVENTHUB_RG" \
    --yes \
    --output none 2>/dev/null || true
  echo "  ✓ Deleted Function App storage: $FUNC_STORAGE_NAME"

  echo ""
  echo "  Deleting Event Hub namespace..."
  az eventhubs namespace delete \
    --name "$EVENTHUB_NS_NAME" \
    --resource-group "$EVENTHUB_RG" \
    --output none 2>/dev/null || true
  echo "  ✓ Deleted Event Hub namespace: $EVENTHUB_NS_NAME"

  echo ""
  echo "[3/3] Deleting region resource group..."
  az group delete \
    --name "$EVENTHUB_RG" \
    --yes \
    --no-wait \
    --output none 2>/dev/null || true
  echo "  ✓ Deleting resource group (async): $EVENTHUB_RG"

else
  echo ""
  echo "[2-3] Skipped (Function App, Event Hub, resource group)."
  echo "      Use --full-cleanup to remove these resources."
fi

# --------------------------------------------------------------------------
# Optional: Delete shared storage account
# --------------------------------------------------------------------------
if [[ "$INCLUDE_STORAGE" == "true" ]]; then
  echo ""
  echo "[Optional] Deleting shared storage account..."

  az storage account delete \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$STORAGE_RG" \
    --yes \
    --output none 2>/dev/null || true
  echo "  ✓ Deleted storage account: $STORAGE_ACCOUNT_NAME"

  az group delete \
    --name "$STORAGE_RG" \
    --yes \
    --no-wait \
    --output none 2>/dev/null || true
  echo "  ✓ Deleting storage resource group (async): $STORAGE_RG"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Cleanup Complete"
echo "=============================================="
echo ""
echo "Removed:"
echo "  - Diagnostic settings from ${#CLUSTER_ARRAY[@]} cluster(s)"
if [[ "$FULL_CLEANUP" == "true" ]]; then
  echo "  - Function App: $FUNC_APP_NAME"
  echo "  - Function App storage: $FUNC_STORAGE_NAME"
  echo "  - Event Hub namespace: $EVENTHUB_NS_NAME"
  echo "  - Resource group: $EVENTHUB_RG (deleting async)"
fi
if [[ "$INCLUDE_STORAGE" == "true" ]]; then
  echo "  - Storage account: $STORAGE_ACCOUNT_NAME"
  echo "  - Storage resource group: $STORAGE_RG (deleting async)"
fi
if [[ "$FULL_CLEANUP" == "false" ]]; then
  echo ""
  echo "Note: Function App, Event Hub, and resource group were NOT deleted."
  echo "      Use --full-cleanup to remove them."
fi
if [[ "$INCLUDE_STORAGE" == "false" ]]; then
  echo ""
  echo "Note: Storage account '$STORAGE_ACCOUNT_NAME' was NOT deleted."
  echo "      Use --include-storage to remove it."
fi
echo ""
