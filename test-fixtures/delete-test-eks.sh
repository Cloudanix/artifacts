#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Tear down the test EKS cluster and its VPC
# =============================================================================
# Run in the EKS test account. Deletes node group, cluster, IAM roles, and VPC.
# =============================================================================
set -uo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
CLUSTER_NAME="${CLUSTER_NAME:-cdx-test-eks}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[OK] $*"; }

# Node group first
if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-ng" > /dev/null 2>&1; then
    log "Deleting node group..."
    aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-ng" > /dev/null
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "${CLUSTER_NAME}-ng"
    ok "Node group deleted"
fi

# Cluster
if aws eks describe-cluster --name "$CLUSTER_NAME" > /dev/null 2>&1; then
    log "Deleting cluster (takes a few min)..."
    aws eks delete-cluster --name "$CLUSTER_NAME" > /dev/null
    aws eks wait cluster-deleted --name "$CLUSTER_NAME"
    ok "Cluster deleted"
fi

# IAM roles
for ROLE in "${CLUSTER_NAME}-cluster-role" "${CLUSTER_NAME}-node-role"; do
    if aws iam get-role --role-name "$ROLE" > /dev/null 2>&1; then
        for P in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
            aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$P" 2>/dev/null || true
        done
        aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
        ok "Deleted role: $ROLE"
    fi
done

# VPC teardown
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    # Delete any leftover ENIs (EKS control plane ENIs)
    for ENI in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
        aws ec2 delete-network-interface --network-interface-id "$ENI" 2>/dev/null || true
    done
    for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
        aws ec2 delete-subnet --subnet-id "$SUB" 2>/dev/null || true
    done
    for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
        aws ec2 delete-security-group --group-id "$SG" 2>/dev/null || true
    done
    for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null); do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
    done
    aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    ok "VPC deleted: $VPC_ID"
fi

ok "Test EKS teardown complete"
