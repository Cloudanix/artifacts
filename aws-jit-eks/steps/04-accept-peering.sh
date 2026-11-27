#!/usr/bin/env bash
# =============================================================================
# Step: Accept VPC Peering (EKS Account)
# =============================================================================
# Run in the EKS CLUSTER account. Accepts an incoming VPC peering connection
# from the JIT bastion hub VPC, updates route tables in the EKS VPC, and adds
# security group rules to allow HTTPS traffic from the hub VPC CIDR.
#
# Required env vars:
#   AWS_REGION, PEERING_CONNECTION_ID, VPC_CIDR, EKS_VPC_ID
#
# Outputs:
#   OUTPUT:PEERING_STATUS=active
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PEERING_CONNECTION_ID EKS_VPC_ID

# VPC_CIDR (hub side) may not be a config field in existing-vpc scope.
# Fall back to reading the requester CIDR directly from the peering connection.
if [[ -z "${VPC_CIDR:-}" ]]; then
    VPC_CIDR=$(aws ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
        --query 'VpcPeeringConnections[0].RequesterVpcInfo.CidrBlock' --output text \
        --region "$AWS_REGION" 2>/dev/null)
fi
if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
    error "Could not determine hub VPC CIDR (VPC_CIDR unset and peering lookup failed)"
    exit 1
fi

# =============================================================================
# ACCEPT PEERING
# =============================================================================

step "Accept VPC Peering"
info "Peering ID: $PEERING_CONNECTION_ID"
info "EKS VPC: $EKS_VPC_ID"
info "Hub VPC CIDR: $VPC_CIDR"

CURRENT_STATUS=$(aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
    --query 'VpcPeeringConnections[0].Status.Code' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [[ "$CURRENT_STATUS" == "active" ]]; then
    ok "Peering already active: $PEERING_CONNECTION_ID"
elif [[ "$CURRENT_STATUS" == "pending-acceptance" ]]; then
    aws ec2 accept-vpc-peering-connection \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$AWS_REGION" > /dev/null

    info "Waiting for peering to become active..."
    for i in $(seq 1 30); do
        STATUS=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
            --query 'VpcPeeringConnections[0].Status.Code' --output text \
            --region "$AWS_REGION")
        if [[ "$STATUS" == "active" ]]; then break; fi
        sleep 5
    done
    ok "Peering accepted and active"
else
    error "Unexpected peering status: $CURRENT_STATUS"
    error "Expected 'pending-acceptance' or 'active'"
    exit 1
fi

# =============================================================================
# UPDATE EKS VPC ROUTE TABLES
# =============================================================================

step "EKS VPC Route Tables"
ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$EKS_VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text --region "$AWS_REGION")

for RT_ID in $ROUTE_TABLES; do
    aws ec2 create-route --route-table-id "$RT_ID" \
        --destination-cidr-block "$VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
done
ok "Routes updated: $VPC_CIDR → $PEERING_CONNECTION_ID"

# =============================================================================
# UPDATE EKS SECURITY GROUPS (allow HTTPS from hub CIDR)
# =============================================================================

step "EKS Security Groups"
# Find EKS cluster security groups in the VPC
EKS_SG_IDS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$EKS_VPC_ID" \
    --query "SecurityGroups[?contains(GroupName, 'eks') || contains(GroupName, 'cluster')].GroupId" \
    --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -n "$EKS_SG_IDS" && "$EKS_SG_IDS" != "None" ]]; then
    for SG_ID in $EKS_SG_IDS; do
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
            --protocol tcp --port 443 --cidr "$VPC_CIDR" \
            --region "$AWS_REGION" > /dev/null 2>&1 || true
        ok "SG $SG_ID: allowed HTTPS (443) from $VPC_CIDR"
    done
else
    warn "No EKS security groups auto-discovered — update manually"
    info "Allow TCP 443 from $VPC_CIDR on the EKS cluster security group"
fi

# =============================================================================
# OUTPUT
# =============================================================================

FINAL_STATUS=$(aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
    --query 'VpcPeeringConnections[0].Status.Code' --output text \
    --region "$AWS_REGION")

ok "Peering acceptance complete (status: $FINAL_STATUS)"
echo "OUTPUT:PEERING_STATUS=${FINAL_STATUS}"
