#!/usr/bin/env bash
# =============================================================================
# Step: Onboard New EKS Cluster — Create Peering (JIT Account)
# =============================================================================
# Peers the EXISTING bastion hub VPC to a NEW EKS cluster's VPC. The new EKS
# cluster may live in a different account and/or region.
#
# Does NOT recreate the bastion — it discovers the existing bastion VPC + SG
# from the prior setup (by the standard bastion SG name).
#
# Required env vars:
#   AWS_REGION           — region of the bastion (requester)
#   EKS_ACCOUNT_ID       — account of the new EKS cluster (accepter)
#   EKS_REGION           — region of the new EKS cluster
#   EKS_VPC_ID           — VPC ID of the new EKS cluster
#   EKS_VPC_CIDR         — CIDR of the new EKS cluster VPC
#
# Outputs:
#   OUTPUT:PEERING_CONNECTION_ID
#   OUTPUT:HUB_VPC_ID
#   OUTPUT:HUB_VPC_CIDR
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION EKS_ACCOUNT_ID EKS_REGION EKS_VPC_ID EKS_VPC_CIDR

export AWS_DEFAULT_REGION="$AWS_REGION"
REQUESTER_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

SG_NAME="cdx-jit-k8s-hub-bastion-sg"

# =============================================================================
# DISCOVER EXISTING BASTION VPC + SG
# =============================================================================

step "Discover Bastion VPC"

BASTION_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -z "$BASTION_SG" || "$BASTION_SG" == "None" ]]; then
    error "Bastion security group '$SG_NAME' not found in this account/region."
    error "Run the initial EKS setup (new-vpc or existing-vpc) first."
    exit 1
fi

HUB_VPC_ID=$(aws ec2 describe-security-groups --group-ids "$BASTION_SG" \
    --query 'SecurityGroups[0].VpcId' --output text)
HUB_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$HUB_VPC_ID" \
    --query 'Vpcs[0].CidrBlock' --output text)

ok "Bastion VPC: $HUB_VPC_ID ($HUB_VPC_CIDR) | SG: $BASTION_SG"
info "New EKS: $EKS_VPC_ID ($EKS_VPC_CIDR) | account: $EKS_ACCOUNT_ID | region: $EKS_REGION"

# =============================================================================
# CREATE PEERING (cross-region / cross-account aware)
# =============================================================================

step "VPC Peering Request"

PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$HUB_VPC_ID" \
              "Name=accepter-vpc-info.vpc-id,Values=$EKS_VPC_ID" \
              "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text 2>/dev/null)

if [[ -n "$PEERING_ID" && "$PEERING_ID" != "None" ]]; then
    ok "Peering already exists: $PEERING_ID"
else
    PEER_REGION_FLAG=""
    if [[ "$EKS_REGION" != "$AWS_REGION" ]]; then
        PEER_REGION_FLAG="--peer-region $EKS_REGION"
    fi

    PEERING_ID=$(aws ec2 create-vpc-peering-connection \
        --vpc-id "$HUB_VPC_ID" \
        --peer-owner-id "$EKS_ACCOUNT_ID" \
        --peer-vpc-id "$EKS_VPC_ID" \
        $PEER_REGION_FLAG \
        --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cdx-jit-eks-peering-${EKS_VPC_ID}},{Key=Purpose,Value=eks-jit},{Key=created_by,Value=cloudanix}]" \
        --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)

    if [[ -z "$PEERING_ID" || "$PEERING_ID" == "None" ]]; then
        error "Failed to create peering connection"; exit 1
    fi
    ok "Peering created: $PEERING_ID"

    # Same account → auto-accept (must accept in accepter's region)
    if [[ "$EKS_ACCOUNT_ID" == "$REQUESTER_ACCOUNT_ID" ]]; then
        info "Same account — auto-accepting (region $EKS_REGION)..."
        sleep 5
        aws ec2 accept-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --region "$EKS_REGION" > /dev/null
        # Update accepter-side routes for same-account
        for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$EKS_VPC_ID" \
            --query 'RouteTables[*].RouteTableId' --output text --region "$EKS_REGION" 2>/dev/null); do
            aws ec2 create-route --route-table-id "$RT" --destination-cidr-block "$HUB_VPC_CIDR" \
                --vpc-peering-connection-id "$PEERING_ID" --region "$EKS_REGION" > /dev/null 2>&1 || true
        done
        ok "Peering auto-accepted (same account)"
    else
        info "Cross-account — run step 07-onboard-accept in the EKS account/region to accept"
    fi
fi

# =============================================================================
# UPDATE HUB (REQUESTER) ROUTE TABLES
# =============================================================================

step "Hub Route Tables"
for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$HUB_VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text); do
    aws ec2 create-route --route-table-id "$RT" \
        --destination-cidr-block "$EKS_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" > /dev/null 2>&1 || \
    aws ec2 replace-route --route-table-id "$RT" \
        --destination-cidr-block "$EKS_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" > /dev/null 2>&1 || true
done
ok "Routes updated for new EKS CIDR: $EKS_VPC_CIDR"

# =============================================================================
# UPDATE BASTION SG (allow HTTPS to new EKS)
# =============================================================================

step "Bastion Security Group"
aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" \
    --protocol tcp --port 443 --cidr "$EKS_VPC_CIDR" > /dev/null 2>&1 || true
ok "SG $BASTION_SG: allowed HTTPS (443) to $EKS_VPC_CIDR"

# =============================================================================
# OUTPUT
# =============================================================================

ok "Onboard peering complete"
echo "OUTPUT:PEERING_CONNECTION_ID=${PEERING_ID}"
echo "OUTPUT:HUB_VPC_ID=${HUB_VPC_ID}"
echo "OUTPUT:HUB_VPC_CIDR=${HUB_VPC_CIDR}"
