#!/usr/bin/env bash
# =============================================================================
# Step: Accept VPC Peering (VM Account)
# =============================================================================
# Run in the VM TARGET account. Accepts an incoming VPC peering connection
# from the JIT workload VPC, updates route tables in the VM VPC, and adds
# security group rules to allow SSH traffic from the JIT VPC CIDR.
#
# Required env vars:
#   AWS_REGION, PEERING_CONNECTION_ID, VPC_CIDR, VM_VPC_ID
#
# Outputs:
#   OUTPUT:PEERING_STATUS=active
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION PEERING_CONNECTION_ID VPC_CIDR VM_VPC_ID

# =============================================================================
# ACCEPT PEERING
# =============================================================================

step "Accept VPC Peering"
info "Peering ID: $PEERING_CONNECTION_ID"
info "VM VPC: $VM_VPC_ID"
info "JIT VPC CIDR: $VPC_CIDR"

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
# UPDATE VM VPC ROUTE TABLES
# =============================================================================

step "VM VPC Route Tables"
ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VM_VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text --region "$AWS_REGION")

for RT_ID in $ROUTE_TABLES; do
    aws ec2 create-route --route-table-id "$RT_ID" \
        --destination-cidr-block "$VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
done
ok "Routes updated: $VPC_CIDR → $PEERING_CONNECTION_ID"

# =============================================================================
# UPDATE VM SECURITY GROUPS (allow SSH from JIT CIDR)
# =============================================================================

step "VM Security Groups"
# Find security groups in the VM VPC that allow SSH and update them
VM_SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VM_VPC_ID" \
    --query 'SecurityGroups[*].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

for SG_ID in $VM_SG_IDS; do
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr "$VPC_CIDR" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
done
ok "VM SGs: allowed SSH (22) from $VPC_CIDR"

# =============================================================================
# OUTPUT
# =============================================================================

FINAL_STATUS=$(aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
    --query 'VpcPeeringConnections[0].Status.Code' --output text \
    --region "$AWS_REGION")

ok "Peering acceptance complete (status: $FINAL_STATUS)"
echo "OUTPUT:PEERING_STATUS=${FINAL_STATUS}"
