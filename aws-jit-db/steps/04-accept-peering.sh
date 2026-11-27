#!/usr/bin/env bash
# =============================================================================
# Step: Accept VPC Peering (DB Account)
# =============================================================================
# Run in the DATABASE account. Accepts an incoming VPC peering connection from
# the JIT workload VPC, updates route tables in the DB VPC, and adds security
# group rules to allow traffic from the JIT VPC CIDR.
#
# Required env vars:
#   AWS_REGION, PEERING_CONNECTION_ID, VPC_CIDR, DB_VPC_ID,
#   DB_SECURITY_GROUP_IDS
#
# Outputs:
#   OUTPUT:PEERING_STATUS
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# SETUP_PEERING controls whether this step does the full peering acceptance +
# route tables, or only security-group whitelisting. Defaults to true so
# existing flows are unchanged.
SETUP_PEERING="${SETUP_PEERING:-true}"

if [[ "$SETUP_PEERING" == "true" ]]; then
    require_env AWS_REGION PEERING_CONNECTION_ID DB_VPC_ID DB_SECURITY_GROUP_IDS
else
    # No-peering mode: we only whitelist the DB security groups for the hub
    # CIDR. Peering acceptance and route tables are skipped.
    require_env AWS_REGION DB_SECURITY_GROUP_IDS HUB_VPC_CIDR
fi

# VPC_CIDR is the hub (requester) CIDR. In onboard-new-account scope it's not a
# config field — fall back to HUB_VPC_CIDR output, then to the peering itself.
if [[ -z "${VPC_CIDR:-}" ]]; then
    VPC_CIDR="${HUB_VPC_CIDR:-}"
fi
if [[ -z "$VPC_CIDR" && "$SETUP_PEERING" == "true" ]]; then
    VPC_CIDR=$(aws ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
        --query 'VpcPeeringConnections[0].RequesterVpcInfo.CidrBlock' --output text \
        --region "$AWS_REGION" 2>/dev/null)
fi
if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
    error "Could not determine hub VPC CIDR"; exit 1
fi

if [[ "$SETUP_PEERING" != "true" ]]; then
    info "VPC peering disabled (SETUP_PEERING=false) — SG whitelisting only"
    info "Hub CIDR: $VPC_CIDR"
fi

# =============================================================================
# ACCEPT PEERING
# =============================================================================

if [[ "$SETUP_PEERING" == "true" ]]; then

step "Accept VPC Peering"
info "Peering ID: $PEERING_CONNECTION_ID"
info "DB VPC: $DB_VPC_ID"
info "JIT VPC CIDR: $VPC_CIDR"

# Check current status
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
# UPDATE DB VPC ROUTE TABLES
# =============================================================================

step "DB VPC Route Tables"
ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$DB_VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text --region "$AWS_REGION")

for RT_ID in $ROUTE_TABLES; do
    aws ec2 create-route --route-table-id "$RT_ID" \
        --destination-cidr-block "$VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_CONNECTION_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
done
ok "Routes updated: $VPC_CIDR → $PEERING_CONNECTION_ID"

fi  # end SETUP_PEERING accept + route tables

# =============================================================================
# UPDATE DB SECURITY GROUPS
# =============================================================================

step "DB Security Groups"
IFS=',' read -ra SG_IDS <<< "$DB_SECURITY_GROUP_IDS"
for SG_ID in "${SG_IDS[@]}"; do
    SG_ID=$(echo "$SG_ID" | xargs)  # trim whitespace
    # Allow PostgreSQL
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 5432 --cidr "$VPC_CIDR" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    # Allow MySQL
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 3306 --cidr "$VPC_CIDR" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    ok "SG $SG_ID: allowed 5432/3306 from $VPC_CIDR"
done

# =============================================================================
# OUTPUT
# =============================================================================

if [[ "$SETUP_PEERING" == "true" ]]; then
    FINAL_STATUS=$(aws ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$PEERING_CONNECTION_ID" \
        --query 'VpcPeeringConnections[0].Status.Code' --output text \
        --region "$AWS_REGION")
    ok "Peering acceptance complete (status: $FINAL_STATUS)"
    echo "OUTPUT:PEERING_STATUS=${FINAL_STATUS}"
else
    ok "SG whitelisting complete (no peering)"
    echo "OUTPUT:PEERING_STATUS=skipped"
fi
