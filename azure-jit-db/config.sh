#!/usr/bin/env bash
# =============================================================================
# Azure JIT DB — Configuration Schema
# =============================================================================

SETUP_TYPE="azure-jit-db"
SETUP_DISPLAY_NAME="Azure JIT Database"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("standard")
SCOPE_MODE_LABELS=(
    "Standard Setup (ACR + ACI + Custom Role + Service Principal)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["standard"]="01-sync-acr 02-setup-infra 03-deploy-aci 04-create-custom-role 05-connect-db 06-create-sp-and-binding"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================

declare -A STEP_ACCOUNT
STEP_ACCOUNT["01-sync-acr"]="jit-subscription"
STEP_ACCOUNT["02-setup-infra"]="jit-subscription"
STEP_ACCOUNT["03-deploy-aci"]="jit-subscription"
STEP_ACCOUNT["04-create-custom-role"]="db-subscription"
STEP_ACCOUNT["05-connect-db"]="db-subscription"
STEP_ACCOUNT["06-create-sp-and-binding"]="jit-subscription"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["01-sync-acr"]="Sync Azure Container Registry Images"
STEP_LABELS["02-setup-infra"]="Setup Infrastructure (VNet, NSG, Storage)"
STEP_LABELS["03-deploy-aci"]="Deploy Azure Container Instance"
STEP_LABELS["04-create-custom-role"]="Create Custom Role (DB Subscription)"
STEP_LABELS["05-connect-db"]="Configure Database Connectivity"
STEP_LABELS["06-create-sp-and-binding"]="Create Service Principal & Role Binding"

# =============================================================================
# ACCOUNT LABELS
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["jit-subscription"]="JIT Workload Subscription"
ACCOUNT_LABELS["db-subscription"]="Database Subscription"

declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["jit-subscription"]="JIT_SUBSCRIPTION_ID"
ACCOUNT_ID_FIELD["db-subscription"]="DB_SUBSCRIPTION_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================

CONFIG_FIELDS=(
    "AZURE_LOCATION|nonempty|eastus|Azure Region|*|false"
    "JIT_SUBSCRIPTION_ID|azure_subscription_id||JIT Workload Subscription ID|*|false"
    "DB_SUBSCRIPTION_ID|azure_subscription_id||Database Subscription ID|*|false"
    "RESOURCE_GROUP|alphanumeric_dash|cdx-jit-db-rg|Resource Group Name|*|false"
    "ACR_NAME|alphanumeric_dash|cdxjitdbacr|Azure Container Registry Name|*|false"
    "ACI_NAME|alphanumeric_dash|cdx-jit-db-aci|Container Instance Name|*|false"
    "VNET_NAME|alphanumeric_dash|cdx-jit-db-vnet|Virtual Network Name|*|false"
    "SUBNET_NAME|alphanumeric_dash|cdx-jit-db-subnet|Subnet Name|*|false"
    "DB_SERVER_NAME|nonempty||Database Server Name|*|false"
    "DB_TYPE|nonempty|postgresql|Database Type (postgresql/mysql)|*|false"
    "CDX_AUTH_TOKEN|nonempty||CDX Auth Token|*|true"
    "CDX_SIGNATURE_SECRET_KEY|nonempty||CDX Signature Secret Key|*|true"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("az" "jq" "docker")
