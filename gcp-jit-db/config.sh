#!/usr/bin/env bash
# =============================================================================
# GCP JIT DB — Configuration Schema
# =============================================================================

SETUP_TYPE="gcp-jit-db"
SETUP_DISPLAY_NAME="GCP JIT Database"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("standard" "existing-vpc")
SCOPE_MODE_LABELS=(
    "Standard Setup (new VPC + full infrastructure)"
    "Existing VPC (deploy into existing network)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["standard"]="01-setup-proxy-prerequisites 02-allow-ar-sync-impersonation 03-sync-artifact-registry 04-setup-infrastructure 05-upload-config-bastion 06-identity-and-workloads 07-setup-psc-cloudsql 08-create-iam-dbuser 09-patch-proxysql 10-optimizations"
STEPS_FOR_MODE["existing-vpc"]="01-setup-proxy-prerequisites 02-allow-ar-sync-impersonation 03-sync-artifact-registry 04-setup-infrastructure 05-upload-config-bastion 06-identity-and-workloads 07-setup-psc-cloudsql 08-create-iam-dbuser 09-patch-proxysql"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================

declare -A STEP_ACCOUNT
STEP_ACCOUNT["01-setup-proxy-prerequisites"]="jit-project"
STEP_ACCOUNT["02-allow-ar-sync-impersonation"]="jit-project"
STEP_ACCOUNT["03-sync-artifact-registry"]="jit-project"
STEP_ACCOUNT["04-setup-infrastructure"]="jit-project"
STEP_ACCOUNT["05-upload-config-bastion"]="jit-project"
STEP_ACCOUNT["06-identity-and-workloads"]="jit-project"
STEP_ACCOUNT["07-setup-psc-cloudsql"]="db-project"
STEP_ACCOUNT["08-create-iam-dbuser"]="db-project"
STEP_ACCOUNT["09-patch-proxysql"]="jit-project"
STEP_ACCOUNT["10-optimizations"]="jit-project"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["01-setup-proxy-prerequisites"]="Setup Prerequisites (APIs, AR, Custom Role)"
STEP_LABELS["02-allow-ar-sync-impersonation"]="Allow AR Sync SA Impersonation"
STEP_LABELS["03-sync-artifact-registry"]="Sync Artifact Registry Images"
STEP_LABELS["04-setup-infrastructure"]="Setup Infrastructure (VPC, Subnets, VM)"
STEP_LABELS["05-upload-config-bastion"]="Upload Config to Bastion"
STEP_LABELS["06-identity-and-workloads"]="Identity and Workloads Setup"
STEP_LABELS["07-setup-psc-cloudsql"]="Setup Private Service Connect for Cloud SQL"
STEP_LABELS["08-create-iam-dbuser"]="Create IAM DB User"
STEP_LABELS["09-patch-proxysql"]="Patch ProxySQL Configuration"
STEP_LABELS["10-optimizations"]="Apply Optimizations"

# =============================================================================
# ACCOUNT LABELS
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["jit-project"]="JIT Workload Project"
ACCOUNT_LABELS["db-project"]="Database (Cloud SQL) Project"

declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["jit-project"]="GCP_PROJECT_ID"
ACCOUNT_ID_FIELD["db-project"]="DB_PROJECT_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================

CONFIG_FIELDS=(
    "GCP_PROJECT_ID|nonempty||GCP Project ID (JIT workload)|*|false"
    "GCP_ORG_ID|nonempty||GCP Organization ID|*|false"
    "DB_PROJECT_ID|nonempty||GCP Project ID (Cloud SQL)|*|false"
    "GCP_REGION|nonempty|us-central1|GCP Region|*|false"
    "GCP_ZONE|nonempty|us-central1-a|GCP Zone|*|false"
    "VPC_NAME|alphanumeric_dash|cdx-jit-db-vpc|VPC Name|standard|false"
    "SUBNET_CIDR|cidr|10.100.0.0/24|Subnet CIDR|standard|false"
    "BASTION_MACHINE_TYPE|nonempty|e2-medium|Bastion VM Machine Type|*|false"
    "CLOUD_SQL_INSTANCE|nonempty||Cloud SQL Instance Name|*|false"
    "CLOUD_SQL_DB_NAME|nonempty||Database Name|*|false"
    "CDX_AUTH_TOKEN|nonempty||CDX Auth Token|*|true"
    "CDX_SIGNATURE_SECRET_KEY|nonempty||CDX Signature Secret Key|*|true"
    "CDX_DC|nonempty|US|CDX Data Center|*|false"
    "CDX_API_BASE|nonempty|https://console.cloudanix.com|CDX API Base URL|*|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("gcloud" "jq" "docker")

# =============================================================================
# GCP-SPECIFIC: Account verification uses gcloud
# =============================================================================

# Override account verification for GCP
verify_gcp_project() {
    local expected_project="$1"
    local actual_project
    actual_project=$(gcloud config get-value project 2>/dev/null) || {
        error "Failed to get GCP project. Run 'gcloud config set project <PROJECT_ID>'"
        return 1
    }
    if [[ "$actual_project" == "$expected_project" ]]; then
        return 0
    fi
    echo "$actual_project"
    return 1
}
