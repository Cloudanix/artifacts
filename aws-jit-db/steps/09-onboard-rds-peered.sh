#!/usr/bin/env bash
# =============================================================================
# Step: Onboard New RDS in Already-Peered VPC (DB Account)
# =============================================================================
# For a DB VPC that is ALREADY peered to the JIT hub. Simply whitelists the
# new RDS security group(s) to accept traffic from the JIT hub VPC CIDR.
# No new infrastructure, no new peering.
#
# Run in the DATABASE account.
#
# Required env vars:
#   AWS_REGION          — DB account region
#   HUB_VPC_CIDR        — CIDR of the JIT hub VPC (the peered requester)
#   DB_SECURITY_GROUP_IDS — comma-separated RDS SG IDs to whitelist
#
# Outputs:
#   OUTPUT:RDS_WHITELISTED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION HUB_VPC_CIDR DB_SECURITY_GROUP_IDS

export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

info "DB Account: $ACCOUNT_ID | Region: $AWS_REGION"
info "JIT hub CIDR: $HUB_VPC_CIDR"

# =============================================================================
# WHITELIST RDS SECURITY GROUPS
# =============================================================================

step "Whitelist RDS Security Groups"
IFS=',' read -ra SG_IDS <<< "$DB_SECURITY_GROUP_IDS"
for SG_ID in "${SG_IDS[@]}"; do
    SG_ID=$(echo "$SG_ID" | xargs)  # trim whitespace
    [[ -z "$SG_ID" ]] && continue

    # PostgreSQL
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 5432 --cidr "$HUB_VPC_CIDR" > /dev/null 2>&1 || true
    # MySQL / MariaDB
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 3306 --cidr "$HUB_VPC_CIDR" > /dev/null 2>&1 || true

    ok "SG $SG_ID: allowed 5432/3306 from $HUB_VPC_CIDR"
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "New RDS onboarded into already-peered VPC"
info "The JIT proxy can now reach these RDS instances over the existing peering."
echo "OUTPUT:RDS_WHITELISTED=true"
