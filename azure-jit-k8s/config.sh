#!/usr/bin/env bash
# =============================================================================
# Azure JIT K8s — Configuration Schema
# =============================================================================

SETUP_TYPE="azure-jit-k8s"
SETUP_DISPLAY_NAME="Azure JIT Kubernetes (AKS)"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("standard")
SCOPE_MODE_LABELS=(
    "Standard Setup (Hub VM + VNet Peering + Custom Roles)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["standard"]="01-create-custom-roles 02-setup-hub-vnet-and-vm 03-setup-peering-role-and-dns 04-extend-role-scopes"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================

declare -A STEP_ACCOUNT
STEP_ACCOUNT["01-create-custom-roles"]="jit-subscription"
STEP_ACCOUNT["02-setup-hub-vnet-and-vm"]="jit-subscription"
STEP_ACCOUNT["03-setup-peering-role-and-dns"]="aks-subscription"
STEP_ACCOUNT["04-extend-role-scopes"]="jit-subscription"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["01-create-custom-roles"]="Create Custom Azure Roles"
STEP_LABELS["02-setup-hub-vnet-and-vm"]="Setup Hub VNet and Bastion VM"
STEP_LABELS["03-setup-peering-role-and-dns"]="Setup Peering Role and DNS"
STEP_LABELS["04-extend-role-scopes"]="Extend Role Scopes"

# =============================================================================
# ACCOUNT LABELS
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["jit-subscription"]="JIT Workload Subscription"
ACCOUNT_LABELS["aks-subscription"]="AKS Cluster Subscription"

declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["jit-subscription"]="JIT_SUBSCRIPTION_ID"
ACCOUNT_ID_FIELD["aks-subscription"]="AKS_SUBSCRIPTION_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================

CONFIG_FIELDS=(
    "AZURE_LOCATION|nonempty|eastus|Azure Region|*|false"
    "JIT_SUBSCRIPTION_ID|azure_subscription_id||JIT Workload Subscription ID|*|false"
    "AKS_SUBSCRIPTION_ID|azure_subscription_id||AKS Cluster Subscription ID|*|false"
    "RESOURCE_GROUP|alphanumeric_dash|cdx-jit-k8s-rg|Resource Group Name|*|false"
    "HUB_VNET_NAME|alphanumeric_dash|cdx-jit-k8s-hub-vnet|Hub VNet Name|*|false"
    "HUB_VNET_CIDR|cidr|10.200.0.0/16|Hub VNet Address Space|*|false"
    "HUB_SUBNET_CIDR|cidr|10.200.1.0/24|Hub Subnet CIDR|*|false"
    "AKS_VNET_ID|nonempty||AKS VNet Resource ID|*|false"
    "AKS_CLUSTER_NAME|nonempty||AKS Cluster Name|*|false"
    "VM_SIZE|nonempty|Standard_B1s|Bastion VM Size|*|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("az" "jq")
