#!/usr/bin/env bash
# =============================================================================
# Step: Create VPC Peering Request
# =============================================================================
# Creates a VPC peering connection from the JIT workload VPC to the database
# VPC (which may be in a different account). Updates requester-side route tables
# and security group rules.
#
# Required env vars:
#   AWS_REGION, VPC_ID, DB_ACCOUNT_ID, DB_VPC_ID, DB_VPC_CIDR, ECS_SG_ID
#
# Outputs:
#   OUTPUT:PEERING_CONNECTION_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION VPC_ID DB_ACCOUNT_ID DB_VPC_ID DB_VPC_CIDR ECS_SG_ID

# =============================================================================
# CHECK EXISTING PEERING
# =============================================================================

step "VPC Peering Request"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

info "Requester VPC: $VPC_ID (account: $ACCOUNT_ID)"
info "Accepter VPC:  $DB_VPC_ID (account: $DB_ACCOUNT_ID)"

PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" \
              "Name=accepter-vpc-info.vpc-id,Values=$DB_VPC_ID" \
              "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [[ -n "$PEERING_ID" && "$PEERING_ID" != "None" ]]; then
    ok "Peering already exists: $PEERING_ID"
else
    # Create the peering request
    PEERING_ID=$(aws ec2 create-vpc-peering-connection \
        --vpc-id "$VPC_ID" \
        --peer-owner-id "$DB_ACCOUNT_ID" \
        --peer-vpc-id "$DB_VPC_ID" \
        --peer-region "$AWS_REGION" \
        --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cdx-jit-db-peering},{Key=Purpose,Value=db-jit},{Key=Environment,Value=Prod},{Key=Created_by,Value=Cloudanix},{Key=purpose,Value=jit_db},{Key=aws-apn-id,Value=${CDX_APN_ID}}]" \
        --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text \
        --region "$AWS_REGION")

    if [[ -z "$PEERING_ID" || "$PEERING_ID" == "None" ]]; then
        error "Failed to create peering connection"; exit 1
    fi
    ok "Peering created: $PEERING_ID"

    # If same account, auto-accept
    if [[ "$DB_ACCOUNT_ID" == "$ACCOUNT_ID" ]]; then
        info "Same account detected — waiting for pending-acceptance..."
        sleep 5
        aws ec2 accept-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --region "$AWS_REGION" > /dev/null
        ok "Peering auto-accepted (same account)"
    else
        info "Cross-account peering — run step 04-accept-peering.sh in the DB account"
    fi
fi

# =============================================================================
# UPDATE REQUESTER-SIDE ROUTES
# =============================================================================

step "Requester Route Tables"
ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text --region "$AWS_REGION")

for RT_ID in $ROUTE_TABLES; do
    aws ec2 create-route --route-table-id "$RT_ID" \
        --destination-cidr-block "$DB_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
done
ok "Routes updated for DB CIDR: $DB_VPC_CIDR"

# =============================================================================
# UPDATE SECURITY GROUP (allow DB ports to peered VPC)
# =============================================================================

step "Security Group Rules"
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
    --protocol tcp --port 5432 --cidr "$DB_VPC_CIDR" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
    --protocol tcp --port 3306 --cidr "$DB_VPC_CIDR" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
ok "SG $ECS_SG_ID: allowed 5432/3306 from $DB_VPC_CIDR"

# =============================================================================
# OUTPUT
# =============================================================================

ok "VPC peering request complete"
echo "OUTPUT:PEERING_CONNECTION_ID=${PEERING_ID}"
