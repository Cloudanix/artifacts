#!/usr/bin/env bash
# =============================================================================
# AWS JIT VM — Configuration Schema
# =============================================================================

SETUP_TYPE="aws-jit-vm"
SETUP_DISPLAY_NAME="AWS JIT VM (SSH Proxy)"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("new-vpc" "existing-vpc")
SCOPE_MODE_LABELS=(
    "New VPC (cross-account VM with VPC peering)"
    "Existing VPC (VM in same or peered network)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["new-vpc"]="01-create-permission-set 02-sync-ecr 03-install-workloads 04-setup-vpc-peering 05-accept-peering 06-store-ssh-key"
STEPS_FOR_MODE["existing-vpc"]="01-create-permission-set 02-sync-ecr 03-install-workloads-existing-vpc 06-store-ssh-key"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================

declare -A STEP_ACCOUNT
STEP_ACCOUNT["01-create-permission-set"]="management"
STEP_ACCOUNT["02-sync-ecr"]="jit-workload"
STEP_ACCOUNT["03-install-workloads"]="jit-workload"
STEP_ACCOUNT["03-install-workloads-existing-vpc"]="jit-workload"
STEP_ACCOUNT["04-setup-vpc-peering"]="jit-workload"
STEP_ACCOUNT["05-accept-peering"]="vm-account"
STEP_ACCOUNT["06-store-ssh-key"]="vm-account"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["01-create-permission-set"]="Create SSO Permission Set"
STEP_LABELS["02-sync-ecr"]="Sync ECR Images"
STEP_LABELS["03-install-workloads"]="Install Workloads (New VPC)"
STEP_LABELS["03-install-workloads-existing-vpc"]="Install Workloads (Existing VPC)"
STEP_LABELS["04-setup-vpc-peering"]="Create VPC Peering Request"
STEP_LABELS["05-accept-peering"]="Accept VPC Peering (VM Account)"
STEP_LABELS["06-store-ssh-key"]="Store VM SSH Key"

# =============================================================================
# ACCOUNT LABELS
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["management"]="Management Account (SSO)"
ACCOUNT_LABELS["jit-workload"]="JIT Workload Account"
ACCOUNT_LABELS["vm-account"]="VM Target Account"

declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["management"]="MGMT_ACCOUNT_ID"
ACCOUNT_ID_FIELD["jit-workload"]="JIT_ACCOUNT_ID"
ACCOUNT_ID_FIELD["vm-account"]="VM_ACCOUNT_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================

CONFIG_FIELDS=(
    "AWS_REGION|region|us-east-1|AWS Region|*|false"
    "JIT_ACCOUNT_ID|aws_account_id||JIT Workload Account ID|*|false"
    "VM_ACCOUNT_ID|aws_account_id||VM Target Account ID|*|false"
    "MGMT_ACCOUNT_ID|aws_account_id||Management Account ID (SSO)|*|false"
    "SSO_INSTANCE_ARN|arn|arn:aws:sso:::instance/ssoins-722367552337aabd|SSO Instance ARN|*|false"
    "PROJECT_NAME|alphanumeric_dash|cdx-jit-vm|Project Name|*|false"
    "CLUSTER_NAME|alphanumeric_dash|cdx-jit-vm-cluster|ECS Cluster Name|*|false"
    "VPC_CIDR|cidr|10.50.0.0/16|VPC CIDR Block|new-vpc|false"
    "S3_BUCKET_NAME|alphanumeric_dash|cdx-jit-vm-recordings|S3 Bucket for Recordings|*|false"
    "CDX_API_AUTH_TOKEN|nonempty||CDX API Auth Token|*|true"
    "CDX_SIGNATURE_SECRET_KEY|nonempty||CDX Signature Secret Key|*|true"
    "CDX_SENTRY_DSN|nonempty||CDX Sentry DSN (optional)|*|false"
    "CDX_DATA_CENTER|nonempty|US|CDX Data Center|*|false"
    "CDX_API_BASE|nonempty|https://console.cloudanix.com/|CDX API Base URL|*|false"
    "VM_VPC_ID|nonempty||VM VPC ID|new-vpc|false"
    "VM_VPC_CIDR|cidr||VM VPC CIDR|new-vpc|false"
    "VPC_ID|nonempty||Existing VPC ID (where ECS workloads run)|existing-vpc|false"
    "PRIVATE_SUBNET_1_ID|nonempty||Private Subnet 1 ID|existing-vpc|false"
    "PRIVATE_SUBNET_2_ID|nonempty||Private Subnet 2 ID|existing-vpc|false"
    "PERMISSION_SET_NAME|alphanumeric_dash|cdx-EcsVmSsmAccess|SSO Permission Set Name|*|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("aws" "jq" "docker")
