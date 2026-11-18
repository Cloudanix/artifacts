#!/usr/bin/env bash
# =============================================================================
# Step: Onboard New VM in Already-Peered VPC (VM Account)
# =============================================================================
# For a VM VPC that is ALREADY peered to the JIT hub. Whitelists SSH (22) on
# the target VM's security group(s) so the JIT proxy (in the hub VPC) can reach
# it over the existing peering. No new infrastructure, no new peering.
#
# Run in the VM TARGET account.
#
# Required env vars:
#   AWS_REGION            — VM account region
#   HUB_VPC_CIDR          — CIDR of the JIT hub VPC (the peered requester)
#   VM_VPC_ID             — the VPC containing the target VM(s)
#
# Optional env vars:
#   VM_SECURITY_GROUP_IDS — comma-separated SG IDs to whitelist. If omitted,
#                           all SGs in VM_VPC_ID are whitelisted.
#
# Outputs:
#   OUTPUT:VM_WHITELISTED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"
export CDX_PURPOSE=jit_vm

require_env AWS_REGION HUB_VPC_CIDR VM_VPC_ID

export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

info "VM Account: $ACCOUNT_ID | Region: $AWS_REGION"
info "JIT hub CIDR: $HUB_VPC_CIDR | VM VPC: $VM_VPC_ID"

# =============================================================================
# RESOLVE TARGET SECURITY GROUPS
# =============================================================================

step "Resolve Security Groups"
if [[ -n "${VM_SECURITY_GROUP_IDS:-}" ]]; then
    IFS=',' read -ra SG_IDS <<< "$VM_SECURITY_GROUP_IDS"
else
    info "No VM_SECURITY_GROUP_IDS given — whitelisting all SGs in $VM_VPC_ID"
    read -ra SG_IDS <<< "$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VM_VPC_ID" \
        --query 'SecurityGroups[*].GroupId' --output text)"
fi

if [[ ${#SG_IDS[@]} -eq 0 ]]; then
    error "No security groups found to whitelist in $VM_VPC_ID"
    exit 1
fi

# =============================================================================
# WHITELIST SSH FROM HUB CIDR
# =============================================================================

step "Whitelist SSH (22) from hub"
for SG_ID in "${SG_IDS[@]}"; do
    SG_ID=$(echo "$SG_ID" | xargs)
    [[ -z "$SG_ID" ]] && continue
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr "$HUB_VPC_CIDR" > /dev/null 2>&1 || true
    ok "SG $SG_ID: allowed SSH (22) from $HUB_VPC_CIDR"
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "New VM onboarded into already-peered VPC"
info "The JIT proxy can now reach VMs in $VM_VPC_ID over the existing peering."
echo "OUTPUT:VM_WHITELISTED=true"
