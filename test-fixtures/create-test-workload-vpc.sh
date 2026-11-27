#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Create a workload-ready VPC (private subnets + NAT)
# =============================================================================
# Provisions a VPC suitable for hosting the JIT DB ECS workload:
#   - public + private subnets across 2 AZs
#   - IGW, NAT gateway, route tables (private → NAT for outbound)
# This is what the existing-vpc / same-account scopes expect the user to
# already have.
#
# Run in the JIT workload account (e.g. 214371877406), us-east-1.
#
# Usage:
#   ./create-test-workload-vpc.sh
#   NAME=cdx-wl-2 VPC_CIDR=10.70.0.0/16 ./create-test-workload-vpc.sh
#
# Outputs: VPC_ID, PRIVATE_SUBNET_1_ID, PRIVATE_SUBNET_2_ID
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

NAME="${NAME:-cdx-test-workload-vpc}"
VPC_CIDR="${VPC_CIDR:-10.70.0.0/16}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[OK] $*"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)

log "Account: $ACCOUNT_ID | Region: $REGION | Name: $NAME | CIDR: $VPC_CIDR"

# VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}},{Key=purpose,Value=cdx-jit-test}]" \
        --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
fi
ok "VPC: $VPC_ID"

subnet() {
    local cidr=$1 az=$2 nm=$3
    local s
    s=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$s" || "$s" == "None" ]]; then
        s=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$nm}]" \
            --query 'Subnet.SubnetId' --output text)
    fi
    echo "$s"
}

PUB_1=$(subnet "${VPC_BASE}.1.0/24" "$AZ_1" "${NAME}-public-1")
PRIV_1=$(subnet "${VPC_BASE}.3.0/24" "$AZ_1" "${NAME}-private-1")
PRIV_2=$(subnet "${VPC_BASE}.4.0/24" "$AZ_2" "${NAME}-private-2")
ok "Subnets: public=$PUB_1 private=$PRIV_1,$PRIV_2"

# IGW
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
ok "IGW: $IGW_ID"

# NAT gateway (in public subnet)
NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
if [[ -z "$NAT_ID" || "$NAT_ID" == "None" ]]; then
    EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_1" --allocation-id "$EIP" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat}]" \
        --query 'NatGateway.NatGatewayId' --output text)
    log "Waiting for NAT gateway..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
fi
ok "NAT: $NAT_ID"

# Public route table
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${NAME}-pub-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-pub-rt}]" \
        --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_1" >/dev/null
fi

# Private route table (→ NAT)
PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${NAME}-priv-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [[ -z "$PRIV_RT" || "$PRIV_RT" == "None" ]]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-priv-rt}]" \
        --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID" >/dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_1" >/dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_2" >/dev/null
fi
ok "Route tables configured (private → NAT)"

echo ""
echo "============================================================"
echo "  Workload VPC ready — values for existing-vpc/same-account:"
echo "============================================================"
echo "  VPC_ID              : $VPC_ID"
echo "  VPC_CIDR            : $VPC_CIDR"
echo "  PRIVATE_SUBNET_1_ID : $PRIV_1"
echo "  PRIVATE_SUBNET_2_ID : $PRIV_2"
echo "============================================================"
