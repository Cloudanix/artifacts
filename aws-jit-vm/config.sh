#!/usr/bin/env bash
# =============================================================================
# AWS JIT VM — Configuration Schema
# =============================================================================

SETUP_TYPE="aws-jit-vm"
SETUP_DISPLAY_NAME="AWS JIT VM (SSH Proxy)"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("new-vpc" "existing-vpc" "onboard-peered" "onboard-new-account")
SCOPE_MODE_LABELS=(
    "New VPC (cross-account VM with VPC peering)"
    "Existing VPC (VM in same or peered network)"
    "Onboard VM in already-peered VPC (reuse existing JIT hub)"
    "Onboard VM in new/unpeered VPC or account (reuse hub, new peering)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

# Note: 02-sync-ecr is intentionally NOT part of any default flow. Images are
# consumed via an ECR pull-through cache by default. The docker sync step is
# only prepended when the operator passes the hidden --sync-ecr flag (handled
# in setup.sh).
declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["new-vpc"]="01-create-permission-set 03-install-workloads 04-setup-vpc-peering 05-accept-peering 06-store-ssh-key"
STEPS_FOR_MODE["existing-vpc"]="01-create-permission-set 03-install-workloads-existing-vpc 06-store-ssh-key"
STEPS_FOR_MODE["onboard-peered"]="07-onboard-peered 06-store-ssh-key"
STEPS_FOR_MODE["onboard-new-account"]="08-onboard-peering 05-accept-peering 06-store-ssh-key"

# Scope modes that install ECS workloads (need image sourcing). Used by setup.sh.
SYNC_ELIGIBLE_MODES="new-vpc existing-vpc"
# The sync step to prepend for this product when --sync-ecr is passed.
SYNC_STEP_ID="02-sync-ecr"
# Pinned default image tag for VM images (no per-service IMAGE_TAG prompt).
CDX_VM_IMAGE_TAG="v0.3.31"

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
STEP_ACCOUNT["07-onboard-peered"]="vm-account"
STEP_ACCOUNT["08-onboard-peering"]="jit-workload"

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
STEP_LABELS["07-onboard-peered"]="Onboard VM (Already-Peered VPC)"
STEP_LABELS["08-onboard-peering"]="Onboard VM (Create Peering)"

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
    "JIT_ACCOUNT_ID|aws_account_id||JIT Workload Account ID|new-vpc,existing-vpc,onboard-new-account|false"
    "VM_ACCOUNT_ID|aws_account_id||VM Target Account ID|new-vpc,existing-vpc,onboard-peered,onboard-new-account|false"
    "MGMT_ACCOUNT_ID|aws_account_id||Management Account ID (SSO)|new-vpc,existing-vpc|false"
    "SSO_INSTANCE_ARN|arn|arn:aws:sso:::instance/ssoins-722367552337aabd|SSO Instance ARN|new-vpc,existing-vpc|false"
    "PROJECT_NAME|alphanumeric_dash|cdx-jit-vm|Project Name|*|false"
    "CLUSTER_NAME|alphanumeric_dash|cdx-jit-vm-cluster|ECS Cluster Name|new-vpc,existing-vpc|false"
    "IMAGE_TAG|semver_or_latest|v0.3.31|Image Tag (e.g. v0.3.31)|new-vpc,existing-vpc|false"
    "VPC_CIDR|cidr|10.50.0.0/16|VPC CIDR Block|new-vpc|false"
    "S3_BUCKET_NAME|alphanumeric_dash|cdx-jit-vm-recordings|S3 Bucket for Recordings|new-vpc,existing-vpc|false"
    "CDX_API_AUTH_TOKEN|nonempty||CDX API Auth Token|new-vpc,existing-vpc|true"
    "CDX_SIGNATURE_SECRET_KEY|nonempty||CDX Signature Secret Key|new-vpc,existing-vpc|true"
    "CDX_SENTRY_DSN|nonempty||CDX Sentry DSN (optional)|new-vpc,existing-vpc|false"
    "CDX_DATA_CENTER|nonempty|US|CDX Data Center|new-vpc,existing-vpc|false"
    "CDX_API_BASE|nonempty|https://console.cloudanix.com/|CDX API Base URL|new-vpc,existing-vpc|false"
    "VM_VPC_ID|nonempty||VM VPC ID|new-vpc,onboard-peered,onboard-new-account|false"
    "VM_VPC_CIDR|cidr||VM VPC CIDR|new-vpc,onboard-new-account|false"
    "VPC_ID|nonempty||Existing VPC ID (where ECS workloads run)|existing-vpc|false"
    "PRIVATE_SUBNET_1_ID|nonempty||Private Subnet 1 ID|existing-vpc|false"
    "PRIVATE_SUBNET_2_ID|nonempty||Private Subnet 2 ID|existing-vpc|false"
    "HUB_VPC_ID|nonempty|__AUTO_HUB_VPC__|JIT hub VPC ID (auto-detected — confirm or override)|onboard-new-account|false"
    "HUB_VPC_CIDR|cidr|__AUTO_HUB_CIDR__|JIT hub VPC CIDR (auto-detected — the peered requester CIDR)|onboard-peered|false"
    "VM_SECURITY_GROUP_IDS|optional||VM Security Group IDs to whitelist (comma-separated, blank = all in VPC)|onboard-peered|false"
    "PERMISSION_SET_NAME|alphanumeric_dash|cdx-EcsVmSsmAccess|SSO Permission Set Name|new-vpc,existing-vpc|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("aws" "jq" "docker")
