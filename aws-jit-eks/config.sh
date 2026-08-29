#!/usr/bin/env bash
# =============================================================================
# AWS JIT EKS — Configuration Schema
# =============================================================================

SETUP_TYPE="aws-jit-eks"
SETUP_DISPLAY_NAME="AWS JIT EKS (Kubernetes)"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("new-vpc" "existing-vpc")
SCOPE_MODE_LABELS=(
    "New VPC (create hub VPC + ECS bastion, peer to EKS)"
    "Existing VPC (ECS bastion in existing network)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["new-vpc"]="01-attach-eks-policies 02-setup-bastion-hub 03-setup-vpc-peering 04-accept-peering 05-create-permission-sets"
STEPS_FOR_MODE["existing-vpc"]="01-attach-eks-policies 02-setup-bastion-existing-vpc 03-setup-vpc-peering 04-accept-peering 05-create-permission-sets"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================

declare -A STEP_ACCOUNT
STEP_ACCOUNT["01-attach-eks-policies"]="jit-workload"
STEP_ACCOUNT["02-setup-bastion-hub"]="jit-workload"
STEP_ACCOUNT["02-setup-bastion-existing-vpc"]="jit-workload"
STEP_ACCOUNT["03-setup-vpc-peering"]="jit-workload"
STEP_ACCOUNT["04-accept-peering"]="eks-account"
STEP_ACCOUNT["05-create-permission-sets"]="management"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["01-attach-eks-policies"]="Attach EKS Policies to Cross-Account Role"
STEP_LABELS["02-setup-bastion-hub"]="Setup Bastion Hub (New VPC)"
STEP_LABELS["02-setup-bastion-existing-vpc"]="Setup Bastion Hub (Existing VPC)"
STEP_LABELS["03-setup-vpc-peering"]="Create VPC Peering to EKS VPC"
STEP_LABELS["04-accept-peering"]="Accept VPC Peering (EKS Account)"
STEP_LABELS["05-create-permission-sets"]="Create SSO Permission Sets"

# =============================================================================
# ACCOUNT LABELS
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["jit-workload"]="JIT Workload Account"
ACCOUNT_LABELS["eks-account"]="EKS Cluster Account"
ACCOUNT_LABELS["management"]="Management Account (SSO)"

declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["jit-workload"]="JIT_ACCOUNT_ID"
ACCOUNT_ID_FIELD["eks-account"]="EKS_ACCOUNT_ID"
ACCOUNT_ID_FIELD["management"]="MGMT_ACCOUNT_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================

CONFIG_FIELDS=(
    "AWS_REGION|region|us-east-1|AWS Region|*|false"
    "JIT_ACCOUNT_ID|aws_account_id||JIT Workload Account ID|*|false"
    "EKS_ACCOUNT_ID|aws_account_id||EKS Cluster Account ID|*|false"
    "MGMT_ACCOUNT_ID|aws_account_id||Management Account ID (SSO)|*|false"
    "SSO_INSTANCE_ARN|nonempty|__AUTO_SSO__|SSO Instance ARN|*|false"
    "ECS_CLUSTER_MODE|nonempty|new|ECS Cluster Mode (new/existing)|*|false"
    "ECS_CLUSTER_NAME|alphanumeric_dash|cdx-jit-k8s-cluster|ECS Cluster Name (new or existing to reuse)|*|false"
    "VPC_CIDR|cidr|10.200.0.0/16|Hub VPC CIDR Block|new-vpc|false"
    "VPC_ID|nonempty||Existing VPC ID (for bastion)|existing-vpc|false"
    "PRIV_SUB_1|nonempty||Private Subnet 1 ID (for bastion)|existing-vpc|false"
    "PRIV_SUB_2|nonempty||Private Subnet 2 ID (optional)|existing-vpc|false"
    "EKS_VPC_ID|nonempty||EKS VPC ID|*|false"
    "EKS_VPC_CIDR|cidr||EKS VPC CIDR|*|false"
    "EKS_CLUSTER_NAME|nonempty||EKS Cluster Name|*|false"
    "EKS_API_ENDPOINT|nonempty||EKS API Server Endpoint|*|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("aws" "jq")
