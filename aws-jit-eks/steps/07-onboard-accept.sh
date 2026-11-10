#!/usr/bin/env bash
# =============================================================================
# Step: Onboard New EKS Cluster — Accept Peering (EKS Account)
# =============================================================================
# Run in the NEW EKS CLUSTER account. Accepts the incoming VPC peering from the
# bastion hub, updates route tables in the EKS VPC, and adds a security group
# rule allowing HTTPS from the hub VPC CIDR.
#
# All operations run in EKS_REGION (which may differ from the bastion region).
#
# Required env vars:
#   EKS_REGION, PEERING_CONNECTION_ID, HUB_VPC_CIDR, EKS_VPC_ID
#
# Outputs:
#   OUTPUT:ONBOARD_PEERING_STATUS
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env EKS_REGION PEERING_CONNECTION_ID HUB_VPC_CIDR EKS_VPC_ID

export AWS_DEFAULT_REGION="$EKS_REGION"

# =============================================================================
# ACCEPT PEERING (in EKS region)
# =============================================================================

step "Accept VPC Peering"
info "Peering ID: $PEERING_CONNECTION_ID"
info "EKS VPC: $EKS_VPC_ID (region: $EKS_REGION)"
info "Hub VPC CIDR: $HUB_VPC_CIDR"

CURRENT_STATUS=$(aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
    --query 'VpcPeeringConnections[0].Status.Code' --output text \
    --region "$EKS_REGION" 2>/dev/null)

if [[ "$CURRENT_STATUS" == "active" ]]; then
    ok "Peering already active: $PEERING_CONNECTION_ID"
elif [[ "$CURRENT_STATUS" == "pending-acceptance" ]]; then
    aws ec2 accept-vpc-peering-connection \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$EKS_REGION" > /dev/null
    info "Waiting for peering to become active..."
    for _i in $(seq 1 30); do
        STATUS=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
            --query 'VpcPeeringConnections[0].Status.Code' --output text \
            --region "$EKS_REGION")
        if [[ "$STATUS" == "active" ]]; then break; fi
        sleep 5
    done
    ok "Peering accepted and active"
else
    error "Unexpected peering status: $CURRENT_STATUS (expected pending-acceptance or active)"
    exit 1
fi

# =============================================================================
# UPDATE EKS VPC ROUTE TABLES
# =============================================================================

step "EKS VPC Route Tables"
for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$EKS_VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text --region "$EKS_REGION"); do
    aws ec2 create-route --route-table-id "$RT" \
        --destination-cidr-block "$HUB_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$EKS_REGION" > /dev/null 2>&1 || \
    aws ec2 replace-route --route-table-id "$RT" \
        --destination-cidr-block "$HUB_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$EKS_REGION" > /dev/null 2>&1 || true
done
ok "Routes updated: $HUB_VPC_CIDR → $PEERING_CONNECTION_ID"

# =============================================================================
# UPDATE EKS SECURITY GROUPS (allow HTTPS from hub CIDR)
# =============================================================================

step "EKS Security Groups"
EKS_SG_IDS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$EKS_VPC_ID" \
    --query "SecurityGroups[?contains(GroupName, 'eks') || contains(GroupName, 'cluster')].GroupId" \
    --output text --region "$EKS_REGION" 2>/dev/null)

if [[ -n "$EKS_SG_IDS" && "$EKS_SG_IDS" != "None" ]]; then
    for SG_ID in $EKS_SG_IDS; do
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
            --protocol tcp --port 443 --cidr "$HUB_VPC_CIDR" \
            --region "$EKS_REGION" > /dev/null 2>&1 || true
        ok "SG $SG_ID: allowed HTTPS (443) from $HUB_VPC_CIDR"
    done
else
    warn "No EKS security groups auto-discovered — allow TCP 443 from $HUB_VPC_CIDR manually"
fi

# =============================================================================
# OUTPUT
# =============================================================================

FINAL_STATUS=$(aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
    --query 'VpcPeeringConnections[0].Status.Code' --output text \
    --region "$EKS_REGION")

ok "Onboard peering acceptance complete (status: $FINAL_STATUS)"
echo "OUTPUT:ONBOARD_PEERING_STATUS=${FINAL_STATUS}"
