#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Create a target VM in a dedicated VPC
# =============================================================================
# Provisions a VPC (public+private subnets, NAT) with a small EC2 "target VM"
# for testing the aws-jit-vm flows:
#   - new-vpc: peer the JIT hub VPC to THIS vpc (use VPC_ID + CIDR)
#   - existing-vpc: deploy the JIT workload INTO this VPC (has private subnets)
#
# Run in the target account (e.g. 214371877406), us-east-1.
#
# Usage:
#   ./create-test-vm.sh
#   NAME=cdx-test-vm VPC_CIDR=10.60.0.0/16 ./create-test-vm.sh
#
# Outputs: VM_VPC_ID, VM_VPC_CIDR, PRIVATE_SUBNET_1_ID, PRIVATE_SUBNET_2_ID,
#          VM instance ID + private IP
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

NAME="${NAME:-cdx-test-vm}"
VPC_CIDR="${VPC_CIDR:-10.60.0.0/16}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
WITH_INSTANCE="${WITH_INSTANCE:-true}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[OK] $*"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)

log "Account: $ACCOUNT_ID | Region: $REGION | Name: $NAME | CIDR: $VPC_CIDR"

# ---------------- VPC + subnets ----------------
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}-vpc},{Key=purpose,Value=cdx-jit-test}]" \
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

# ---------------- IGW + NAT + routes ----------------
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi

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

PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${NAME}-pub-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-pub-rt}]" \
        --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_1" >/dev/null
fi
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
ok "Route tables configured"

# ---------------- Target EC2 VM (in private subnet) ----------------
INSTANCE_ID=""
PRIVATE_IP=""
if [[ "$WITH_INSTANCE" == "true" ]]; then
    VM_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${NAME}-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    if [[ -z "$VM_SG" || "$VM_SG" == "None" ]]; then
        VM_SG=$(aws ec2 create-security-group --group-name "${NAME}-sg" \
            --description "Test VM SG - SSH from VPC" --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME}-sg}]" \
            --query 'GroupId' --output text)
        # Allow SSH from within the VPC and from peered ranges (broad for testing)
        aws ec2 authorize-security-group-ingress --group-id "$VM_SG" --protocol tcp --port 22 --cidr "10.0.0.0/8" >/dev/null 2>&1 || true
    fi

    EXISTING=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${NAME}-instance" "Name=vpc-id,Values=$VPC_ID" \
                  "Name=instance-state-name,Values=running,pending,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
    if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
        INSTANCE_ID="$EXISTING"
    else
        AMI_ID=$(aws ec2 describe-images --owners amazon \
            --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
            --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
        log "Launching target VM ($INSTANCE_TYPE, AMI $AMI_ID)..."
        INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
            --subnet-id "$PRIV_1" --security-group-ids "$VM_SG" \
            --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}-instance},{Key=purpose,Value=cdx-jit-test}]" \
            --query 'Instances[0].InstanceId' --output text)
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    fi
    PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
    ok "Target VM: $INSTANCE_ID ($PRIVATE_IP)"
fi

# ---------------- Output ----------------
echo ""
echo "============================================================"
echo "  Test VM environment ready:"
echo "============================================================"
echo "  Account             : $ACCOUNT_ID"
echo "  VM_VPC_ID           : $VPC_ID"
echo "  VM_VPC_CIDR         : $VPC_CIDR"
echo "  PRIVATE_SUBNET_1_ID : $PRIV_1"
echo "  PRIVATE_SUBNET_2_ID : $PRIV_2"
if [[ -n "$INSTANCE_ID" ]]; then
echo "  Target VM instance  : $INSTANCE_ID ($PRIVATE_IP)"
fi
echo "============================================================"
echo ""
echo "  new-vpc test    : VM VPC ID = $VPC_ID, VM VPC CIDR = $VPC_CIDR"
echo "  existing-vpc    : deploy workload into VPC $VPC_ID using the private subnets above"
