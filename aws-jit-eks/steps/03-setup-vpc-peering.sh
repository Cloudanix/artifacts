#!/usr/bin/env bash
# =============================================================================
# Step: Create VPC Peering (Hub → EKS)
# =============================================================================
# Creates a VPC peering connection from the JIT bastion hub VPC to the EKS
# cluster VPC (which may be in a different account). Updates requester-side
# route tables and security group rules to allow HTTPS traffic.
#
# Required env vars:
#   AWS_REGION, VPC_ID, EKS_ACCOUNT_ID, EKS_VPC_ID, EKS_VPC_CIDR
#
# Outputs:
#   OUTPUT:PEERING_CONNECTION_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION VPC_ID EKS_ACCOUNT_ID EKS_VPC_ID EKS_VPC_CIDR

# =============================================================================
# CHECK EXISTING PEERING
# =============================================================================

step "VPC Peering Request"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

info "Requester VPC (hub): $VPC_ID (account: $ACCOUNT_ID)"
info "Accepter VPC (EKS):  $EKS_VPC_ID (account: $EKS_ACCOUNT_ID)"

PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" \
              "Name=accepter-vpc-info.vpc-id,Values=$EKS_VPC_ID" \
              "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [[ -n "$PEERING_ID" && "$PEERING_ID" != "None" ]]; then
    ok "Peering already exists: $PEERING_ID"
else
    PEERING_ID=$(aws ec2 create-vpc-peering-connection \
        --vpc-id "$VPC_ID" \
        --peer-owner-id "$EKS_ACCOUNT_ID" \
        --peer-vpc-id "$EKS_VPC_ID" \
        --peer-region "$AWS_REGION" \
        --tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cdx-jit-eks-peering},{Key=Purpose,Value=eks-jit},{Key=Environment,Value=Prod},{Key=Created_by,Value=Cloudanix},{Key=purpose,Value=jit_k8s}]" \
        --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text \
        --region "$AWS_REGION")

    if [[ -z "$PEERING_ID" || "$PEERING_ID" == "None" ]]; then
        error "Failed to create peering connection"; exit 1
    fi
    ok "Peering created: $PEERING_ID"

    # Same account → auto-accept
    if [[ "$EKS_ACCOUNT_ID" == "$ACCOUNT_ID" ]]; then
        info "Same account detected — auto-accepting..."
        sleep 5
        aws ec2 accept-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --region "$AWS_REGION" > /dev/null
        ok "Peering auto-accepted (same account)"
    else
        info "Cross-account peering — run step 04-accept-peering.sh in the EKS account"
    fi
fi

# =============================================================================
# UPDATE REQUESTER-SIDE ROUTES
# =============================================================================

step "Hub Route Tables"
ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[*].RouteTableId' --output text --region "$AWS_REGION")

for RT_ID in $ROUTE_TABLES; do
    aws ec2 create-route --route-table-id "$RT_ID" \
        --destination-cidr-block "$EKS_VPC_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
done
ok "Routes updated for EKS CIDR: $EKS_VPC_CIDR"

# =============================================================================
# UPDATE BASTION SG (allow HTTPS to EKS)
# =============================================================================

step "Security Group Rules"
# Find bastion SG in the hub VPC
BASTION_SG=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=cdx-jit-k8s-hub-bastion-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [[ -n "$BASTION_SG" && "$BASTION_SG" != "None" ]]; then
    aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" \
        --protocol tcp --port 443 --cidr "$EKS_VPC_CIDR" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    ok "SG $BASTION_SG: allowed HTTPS (443) from $EKS_VPC_CIDR"
fi

# =============================================================================
# OUTPUT
# =============================================================================

ok "VPC peering request complete"
echo "OUTPUT:PEERING_CONNECTION_ID=${PEERING_ID}"
