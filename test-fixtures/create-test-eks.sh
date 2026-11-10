#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Create a minimal EKS cluster in a dedicated VPC
# =============================================================================
# Creates a test EKS cluster (control plane only by default) in its own VPC
# so we can test the aws-jit-eks setup end-to-end (peering, bastion
# port-forward, EKS access entries).
#
# Run this in the EKS test account (e.g. 952490538873).
#
# Usage:
#   ./create-test-eks.sh                 # control plane only (~15 min)
#   WITH_NODES=true ./create-test-eks.sh # + 1 small node group (~20 min)
#
# Outputs the values you'll need for the JIT EKS setup:
#   EKS_VPC_ID, EKS_VPC_CIDR, EKS_CLUSTER_NAME, EKS_API_ENDPOINT
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

CLUSTER_NAME="${CLUSTER_NAME:-cdx-test-eks}"
VPC_CIDR="${VPC_CIDR:-10.100.0.0/16}"
WITH_NODES="${WITH_NODES:-false}"
K8S_VERSION="${K8S_VERSION:-1.30}"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
ok()   { echo "[OK] $*"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Account: $ACCOUNT_ID | Region: $REGION | Cluster: $CLUSTER_NAME"

AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)

# =============================================================================
# VPC + SUBNETS (EKS needs at least 2 AZs)
# =============================================================================

log "Creating VPC ($VPC_CIDR)..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-vpc},{Key=purpose,Value=cdx-jit-test}]" \
        --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
fi
ok "VPC: $VPC_ID"

VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)

create_subnet() {
    local cidr=$1 az=$2 name=$3
    local sid
    sid=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$sid" || "$sid" == "None" ]]; then
        sid=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name}]" \
            --query 'Subnet.SubnetId' --output text)
    fi
    echo "$sid"
}

SUB_1=$(create_subnet "${VPC_BASE}.1.0/24" "$AZ_1" "${CLUSTER_NAME}-subnet-1")
SUB_2=$(create_subnet "${VPC_BASE}.2.0/24" "$AZ_2" "${CLUSTER_NAME}-subnet-2")
ok "Subnets: $SUB_1, $SUB_2"

# IGW + route (EKS control plane needs internet for the managed ENIs in public mode)
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" 2>/dev/null || true
ok "IGW + route configured"

# =============================================================================
# EKS CLUSTER IAM ROLE
# =============================================================================

CLUSTER_ROLE="${CLUSTER_NAME}-cluster-role"
ROLE_ARN=$(aws iam get-role --role-name "$CLUSTER_ROLE" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$CLUSTER_ROLE" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$CLUSTER_ROLE" --query 'Role.Arn' --output text)
fi
aws iam attach-role-policy --role-name "$CLUSTER_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" 2>/dev/null || true
ok "Cluster role: $CLUSTER_ROLE"

# =============================================================================
# CREATE EKS CLUSTER
# =============================================================================

CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.status' --output text 2>/dev/null) || CLUSTER_STATUS=""

if [[ -z "$CLUSTER_STATUS" ]]; then
    log "Creating EKS cluster (this takes ~10-15 min)..."
    aws eks create-cluster --name "$CLUSTER_NAME" \
        --role-arn "$ROLE_ARN" \
        --kubernetes-version "$K8S_VERSION" \
        --resources-vpc-config "subnetIds=${SUB_1},${SUB_2},endpointPublicAccess=true,endpointPrivateAccess=true" \
        --access-config "authenticationMode=API_AND_CONFIG_MAP" > /dev/null
    log "Waiting for cluster to become ACTIVE..."
    aws eks wait cluster-active --name "$CLUSTER_NAME"
    ok "Cluster ACTIVE"
else
    ok "Cluster exists (status: $CLUSTER_STATUS)"
fi

# =============================================================================
# OPTIONAL NODE GROUP
# =============================================================================

if [[ "$WITH_NODES" == "true" ]]; then
    NODE_ROLE="${CLUSTER_NAME}-node-role"
    NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE" --query 'Role.Arn' --output text 2>/dev/null) || NODE_ROLE_ARN=""
    if [[ -z "$NODE_ROLE_ARN" ]]; then
        aws iam create-role --role-name "$NODE_ROLE" \
            --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null
        NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE" --query 'Role.Arn' --output text)
    fi
    for P in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly; do
        aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "arn:aws:iam::aws:policy/$P" 2>/dev/null || true
    done

    NG_STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-ng" \
        --query 'nodegroup.status' --output text 2>/dev/null) || NG_STATUS=""
    if [[ -z "$NG_STATUS" ]]; then
        log "Creating node group (~5 min)..."
        aws eks create-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-ng" \
            --node-role "$NODE_ROLE_ARN" --subnets "$SUB_1" "$SUB_2" \
            --scaling-config "minSize=1,maxSize=1,desiredSize=1" \
            --instance-types "t3.small" > /dev/null
        aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-ng"
        ok "Node group ACTIVE"
    else
        ok "Node group exists (status: $NG_STATUS)"
    fi
fi

# =============================================================================
# OUTPUT
# =============================================================================

EKS_ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.endpoint' --output text)
# strip https:// prefix for the port-forward host value
EKS_HOST=$(echo "$EKS_ENDPOINT" | sed 's|https://||')

echo ""
echo "============================================================"
echo "  Test EKS cluster ready — values for aws-jit-eks setup:"
echo "============================================================"
echo "  EKS_ACCOUNT_ID   : $ACCOUNT_ID"
echo "  EKS_VPC_ID       : $VPC_ID"
echo "  EKS_VPC_CIDR     : $VPC_CIDR"
echo "  EKS_CLUSTER_NAME : $CLUSTER_NAME"
echo "  EKS_API_ENDPOINT : $EKS_HOST"
echo "  (full endpoint)  : $EKS_ENDPOINT"
echo "  Subnets          : $SUB_1, $SUB_2"
echo "============================================================"
