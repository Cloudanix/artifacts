#!/usr/bin/env bash
# =============================================================================
# Step: Onboard New DB Account — Create Peering (JIT Account)
# =============================================================================
# For onboarding the first DB from a NEW (unpeered) account. Reuses the
# existing JIT hub/bastion VPC and peers it to the new DB account's VPC.
#
# Discovers the existing hub VPC from the ECS security group created by the
# original setup (<project>-ecs-sg).
#
# Required env vars:
#   AWS_REGION, DB_ACCOUNT_ID, DB_VPC_ID, DB_VPC_CIDR, PROJECT_NAME
#   HUB_VPC_ID  — confirmed hub VPC (auto-detected default in config)
#
# Outputs:
#   OUTPUT:PEERING_CONNECTION_ID, OUTPUT:HUB_VPC_ID, OUTPUT:HUB_VPC_CIDR
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION DB_ACCOUNT_ID DB_VPC_ID DB_VPC_CIDR PROJECT_NAME HUB_VPC_ID

export AWS_DEFAULT_REGION="$AWS_REGION"
REQUESTER_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

ECS_SG_NAME="${PROJECT_NAME}-ecs-sg"

# =============================================================================
# RESOLVE HUB VPC CIDR + ECS SG
# =============================================================================

step "Hub VPC"
HUB_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$HUB_VPC_ID" \
    --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null)
if [[ -z "$HUB_VPC_CIDR" || "$HUB_VPC_CIDR" == "None" ]]; then
    error "Hub VPC '$HUB_VPC_ID' not found. Run the initial DB setup first."
    exit 1
fi

ECS_SG=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$HUB_VPC_ID" "Name=group-name,Values=$ECS_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[[ "$ECS_SG" == "None" ]] && ECS_SG=""

ok "Hub VPC: $HUB_VPC_ID ($HUB_VPC_CIDR) | ECS SG: ${ECS_SG:-<not found>}"
info "New DB VPC: $DB_VPC_ID ($DB_VPC_CIDR) | account: $DB_ACCOUNT_ID"

# =============================================================================
# CREATE PEERING
# =============================================================================

step "VPC Peering Request"
PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$HUB_VPC_ID" \
              "Name=accepter-vpc-info.vpc-id,Values=$DB_VPC_ID" \
              "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text 2>/dev/null)

if [[ -n "$PEERING_ID" && "$PEERING_ID" != "None" ]]; then
    ok "Peering already exists: $PEERING_ID"
else
    PEERING_ID=$(aws ec2 create-vpc-peering-connection \
        --vpc-id "$HUB_VPC_ID" \
        --peer-owner-id "$DB_ACCOUNT_ID" \
        --peer-vpc-id "$DB_VPC_ID" \
        --peer-region "$AWS_REGION" \
        --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cdx-jit-db-peering-${DB_VPC_ID}},{Key=Purpose,Value=db-jit},{Key=created_by,Value=cloudanix}]" \
        --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)

    if [[ -z "$PEERING_ID" || "$PEERING_ID" == "None" ]]; then
        error "Failed to create peering connection"; exit 1
    fi
    ok "Peering created: $PEERING_ID"

    if [[ "$DB_ACCOUNT_ID" == "$REQUESTER_ACCOUNT_ID" ]]; then
        info "Same account — auto-accepting..."
        sleep 5
        aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PEERING_ID" > /dev/null
        ok "Peering auto-accepted (same account)"
    else
        info "Cross-account — step 04-accept-peering runs in the DB account"
    fi
fi

# =============================================================================
# UPDATE HUB ROUTE TABLES + ECS SG
# =============================================================================

step "Hub Route Tables"
for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$HUB_VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text); do
    aws ec2 create-route --route-table-id "$RT" \
        --destination-cidr-block "$DB_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" > /dev/null 2>&1 || \
    aws ec2 replace-route --route-table-id "$RT" \
        --destination-cidr-block "$DB_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" > /dev/null 2>&1 || true
done
ok "Routes updated for new DB CIDR: $DB_VPC_CIDR"

if [[ -n "$ECS_SG" ]]; then
    step "ECS Security Group"
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" \
        --protocol tcp --port 5432 --cidr "$DB_VPC_CIDR" > /dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" \
        --protocol tcp --port 3306 --cidr "$DB_VPC_CIDR" > /dev/null 2>&1 || true
    ok "ECS SG $ECS_SG: allowed 5432/3306 to $DB_VPC_CIDR"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "Onboard peering complete"
echo "OUTPUT:PEERING_CONNECTION_ID=${PEERING_ID}"
echo "OUTPUT:HUB_VPC_ID=${HUB_VPC_ID}"
echo "OUTPUT:HUB_VPC_CIDR=${HUB_VPC_CIDR}"
