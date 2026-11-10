#!/usr/bin/env bash
# =============================================================================
# AWS JIT EKS — Configuration Schema
# =============================================================================

SETUP_TYPE="aws-jit-eks"
SETUP_DISPLAY_NAME="AWS JIT EKS (Kubernetes)"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("new-vpc" "existing-vpc" "onboard-cluster")
SCOPE_MODE_LABELS=(
    "New VPC (create hub VPC + ECS bastion, peer to EKS)"
    "Existing VPC (ECS bastion in existing network)"
    "Onboard another EKS cluster (reuse existing bastion, peer to new cluster)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["new-vpc"]="01-attach-eks-policies 02-setup-bastion-hub 03-setup-vpc-peering 04-accept-peering 05-create-permission-sets"
STEPS_FOR_MODE["existing-vpc"]="01-attach-eks-policies 02-setup-bastion-existing-vpc 03-setup-vpc-peering 04-accept-peering 05-create-permission-sets"
STEPS_FOR_MODE["onboard-cluster"]="06-onboard-peering 07-onboard-accept 05-create-permission-sets"

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
STEP_ACCOUNT["06-onboard-peering"]="jit-workload"
STEP_ACCOUNT["07-onboard-accept"]="eks-account"

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
STEP_LABELS["06-onboard-peering"]="Peer Bastion to New EKS Cluster"
STEP_LABELS["07-onboard-accept"]="Accept Peering for New Cluster (EKS Account)"

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
    "AWS_REGION|region|us-east-1|AWS Region of the bastion (JIT workload account)|*|false"
    "JIT_ACCOUNT_ID|aws_account_id||JIT Workload Account ID (where the bastion runs)|*|false"
    "EKS_ACCOUNT_ID|aws_account_id||EKS Cluster Account ID (can be the same as JIT account)|*|false"
    "MGMT_ACCOUNT_ID|aws_account_id||Management Account ID (where IAM Identity Center / SSO lives)|new-vpc,existing-vpc|false"
    "SSO_INSTANCE_ARN|nonempty|__AUTO_SSO__|SSO Instance ARN|new-vpc,existing-vpc|false"
    "ECS_CLUSTER_MODE|nonempty|new|ECS cluster: 'new' to create one, or 'existing' to reuse a cluster from your JIT DB/VM setup (new/existing)|new-vpc,existing-vpc|false"
    "ECS_CLUSTER_NAME|alphanumeric_dash|cdx-jit-k8s-cluster|ECS cluster name — if reusing, enter your existing JIT DB/VM cluster (e.g. cdx-jit-db-cluster); if new, a name to create|new-vpc,existing-vpc|false"
    "VPC_CIDR|cidr|10.200.0.0/16|CIDR for the new hub VPC (must NOT overlap your EKS VPC CIDR)|new-vpc|false"
    "VPC_ID|nonempty||Existing VPC ID where the bastion will run (e.g. vpc-0abc123)|existing-vpc|false"
    "PRIV_SUB_1|nonempty||Private subnet ID for the bastion — needs NAT or SSM/ECR VPC endpoints (e.g. subnet-0abc123)|existing-vpc|false"
    "PRIV_SUB_2|nonempty||Second private subnet ID for HA (optional, press Enter to skip)|existing-vpc|false"
    "HUB_VPC_ID|nonempty|__AUTO_BASTION_VPC__|Bastion hub VPC ID (auto-detected — confirm or override)|onboard-cluster|false"
    "EKS_REGION|region|us-east-1|Region of the EKS cluster (can differ from bastion region)|onboard-cluster|false"
    "EKS_VPC_ID|nonempty||VPC ID of the EKS cluster to connect to (e.g. vpc-0def456)|*|false"
    "EKS_VPC_CIDR|cidr||CIDR block of the EKS cluster VPC (e.g. 10.100.0.0/16)|*|false"
    "EKS_CLUSTER_NAME|nonempty||Name of the target EKS cluster (e.g. prod-eks)|new-vpc,existing-vpc|false"
    "EKS_API_ENDPOINT|nonempty||EKS API server endpoint WITHOUT https:// (e.g. ABC123.gr7.us-east-1.eks.amazonaws.com)|new-vpc,existing-vpc|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("aws" "jq")
