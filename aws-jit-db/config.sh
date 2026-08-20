#!/usr/bin/env bash
# =============================================================================
# AWS JIT Database — Configuration Schema
# =============================================================================
# Defines scope modes, step sequences, account contexts, and configuration
# fields for the AWS JIT Database setup orchestrator.
# =============================================================================

# Setup type identifier
SETUP_TYPE="aws-jit-db"
SETUP_DISPLAY_NAME="AWS JIT Database"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("new-vpc" "existing-vpc" "same-account")
SCOPE_MODE_LABELS=(
    "New VPC (cross-account DB with VPC peering)"
    "Existing VPC (cross-account DB, first setup)"
    "Existing VPC (same-account DB or additional setup)"
)

# =============================================================================
# STEPS PER SCOPE MODE (ordered execution sequence)
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["new-vpc"]="01-sync-ecr 02-install-workloads-new-vpc 03-setup-vpc-peering 04-accept-peering 05-extend-role-permissions 06-extend-role-trust 07-update-assume-role 08-create-permission-set"
STEPS_FOR_MODE["existing-vpc"]="01-sync-ecr 02-install-workloads-existing-vpc 05-extend-role-permissions 06-extend-role-trust 07-update-assume-role 08-create-permission-set"
STEPS_FOR_MODE["same-account"]="01-sync-ecr 02-install-workloads-same-account 07-update-assume-role 08-create-permission-set"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================
# Values correspond to config field names for account IDs:
#   jit-workload  → JIT_ACCOUNT_ID
#   db-account    → DB_ACCOUNT_ID
#   management    → MGMT_ACCOUNT_ID

declare -A STEP_ACCOUNT
STEP_ACCOUNT["01-sync-ecr"]="jit-workload"
STEP_ACCOUNT["02-install-workloads-new-vpc"]="jit-workload"
STEP_ACCOUNT["02-install-workloads-existing-vpc"]="jit-workload"
STEP_ACCOUNT["02-install-workloads-same-account"]="jit-workload"
STEP_ACCOUNT["03-setup-vpc-peering"]="jit-workload"
STEP_ACCOUNT["04-accept-peering"]="db-account"
STEP_ACCOUNT["05-extend-role-permissions"]="db-account"
STEP_ACCOUNT["06-extend-role-trust"]="db-account"
STEP_ACCOUNT["07-update-assume-role"]="jit-workload"
STEP_ACCOUNT["08-create-permission-set"]="management"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["01-sync-ecr"]="Sync ECR Images"
STEP_LABELS["02-install-workloads-new-vpc"]="Install Workloads (New VPC)"
STEP_LABELS["02-install-workloads-existing-vpc"]="Install Workloads (Existing VPC)"
STEP_LABELS["02-install-workloads-same-account"]="Install Workloads (Same Account)"
STEP_LABELS["03-setup-vpc-peering"]="Create VPC Peering Request"
STEP_LABELS["04-accept-peering"]="Accept VPC Peering (DB Account)"
STEP_LABELS["05-extend-role-permissions"]="Extend Role Permissions (DB Account)"
STEP_LABELS["06-extend-role-trust"]="Extend Role Trust Policy (DB Account)"
STEP_LABELS["07-update-assume-role"]="Update ECS Assume Role Policy"
STEP_LABELS["08-create-permission-set"]="Create SSO Permission Set"

# =============================================================================
# ACCOUNT LABELS (for display in account switch banners)
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["jit-workload"]="JIT Workload Account"
ACCOUNT_LABELS["db-account"]="Database/RDS Account"
ACCOUNT_LABELS["management"]="Management Account (SSO)"

# Map account context → config field for account ID
declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["jit-workload"]="JIT_ACCOUNT_ID"
ACCOUNT_ID_FIELD["db-account"]="DB_ACCOUNT_ID"
ACCOUNT_ID_FIELD["management"]="MGMT_ACCOUNT_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================
# Format: NAME|VALIDATION_RULE|DEFAULT|PROMPT|SCOPE_MODES|SENSITIVE
#
# SCOPE_MODES: comma-separated list of modes that need this field, or * for all
# SENSITIVE: true/false — if true, value is masked in summary display
# =============================================================================

CONFIG_FIELDS=(
    "AWS_REGION|region|us-east-1|AWS Region|*|false"
    "JIT_ACCOUNT_ID|aws_account_id||JIT Workload Account ID|*|false"
    "DB_ACCOUNT_ID|aws_account_id||Database Account ID|new-vpc,existing-vpc|false"
    "MGMT_ACCOUNT_ID|aws_account_id||Management Account ID (SSO)|*|false"
    "SSO_INSTANCE_ARN|nonempty|__AUTO_SSO__|SSO Instance ARN|*|false"
    "PROJECT_NAME|alphanumeric_dash|cdx-jit-db|Project Name|*|false"
    "ECS_CLUSTER_NAME|alphanumeric_dash|cdx-jit-db-cluster|ECS Cluster Name|new-vpc,existing-vpc|false"
    "IMAGE_TAG|semver_or_latest|latest|Image Tag|*|false"
    "ENABLE_DAM|boolean|false|Enable Database Activity Monitoring (DAM)|*|false"
    "VPC_CIDR|cidr|10.50.0.0/16|VPC CIDR Block|new-vpc|false"
    "VPC_ID|nonempty||Existing VPC ID|existing-vpc,same-account|false"
    "PRIVATE_SUBNET_1_ID|nonempty||Private Subnet 1 ID|existing-vpc,same-account|false"
    "PRIVATE_SUBNET_2_ID|nonempty||Private Subnet 2 ID|existing-vpc,same-account|false"
    "SETUP_NUMBER|nonempty|2|Setup Number (for multi-VPC in same account)|same-account|false"
    "BUCKET_NAME|nonempty|__AUTO_BUCKET__|S3 Bucket Name (for query logs)|*|false"
    "SECRET_NAME|nonempty|CDX_SECRETS|Secrets Manager Secret Name|*|false"
    "CDX_AUTH_TOKEN|nonempty||CDX Auth Token|*|true"
    "CDX_SIGNATURE_SECRET_KEY|nonempty||CDX Signature Secret Key|*|true"
    "CDX_SENTRY_DSN|nonempty|CDX_SENTRY_DSN|CDX Sentry DSN|*|false"
    "CDX_DC|nonempty|US|CDX Data Center (US/EU)|*|false"
    "CDX_API_BASE|nonempty|https://console.cloudanix.com|CDX API Base URL|*|false"
    "DB_VPC_ID|nonempty||Database VPC ID|new-vpc|false"
    "DB_VPC_CIDR|cidr||Database VPC CIDR|new-vpc|false"
    "DB_SECURITY_GROUP_IDS|nonempty||RDS Security Group IDs (comma-separated)|new-vpc|false"
    "PERMISSION_SET_NAME|alphanumeric_dash|cdx-EcsSsmAccess|SSO Permission Set Name|*|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("aws" "jq" "docker")
