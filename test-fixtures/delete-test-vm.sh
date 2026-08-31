#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Tear down the test VM environment
# =============================================================================
set -uo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
NAME="${NAME:-cdx-test-vm}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[OK] $*"; }

# Terminate EC2
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME}-instance" "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || true
    ok "Instance terminated: $INSTANCE_ID"
fi

# VPC teardown (reuse the workload-vpc teardown pattern)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    log "No VPC named ${NAME}-vpc found."
    exit 0
fi
log "Tearing down VPC $VPC_ID ($NAME)..."

for NAT in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" >/dev/null 2>&1 || true
done
log "Waiting for NAT gateway(s) to delete..."
sleep 40
for EIP in $(aws ec2 describe-addresses --query "Addresses[?Domain=='vpc'].AllocationId" --output text 2>/dev/null); do
    aws ec2 release-address --allocation-id "$EIP" 2>/dev/null || true
done
for ENI in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null); do
    aws ec2 delete-network-interface --network-interface-id "$ENI" 2>/dev/null || true
done
for PCX in $(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" "Name=status-code,Values=active,pending-acceptance" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true
done
for PCX in $(aws ec2 describe-vpc-peering-connections \
    --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC_ID" "Name=status-code,Values=active,pending-acceptance" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" 2>/dev/null || true
done
for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$SUB" 2>/dev/null || true
done
for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$SG" 2>/dev/null || true
done
for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
done
for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null); do
    for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
        --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
        aws ec2 disassociate-route-table --association-id "$ASSOC" 2>/dev/null || true
    done
    aws ec2 delete-route-table --route-table-id "$RT" 2>/dev/null || true
done
aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
ok "VPC deleted: $VPC_ID"
