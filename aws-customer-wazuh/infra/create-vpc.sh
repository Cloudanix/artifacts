#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
: "${AWS_REGION:?Set AWS_REGION to the target region}"

NAME_PREFIX="${NAME_PREFIX:-wazuh}"
VPC_CIDR="${VPC_CIDR:-10.100.0.0/16}"
PUB1_CIDR="${PUB1_CIDR:-10.100.1.0/24}"
PUB2_CIDR="${PUB2_CIDR:-10.100.2.0/24}"
PRIV1_CIDR="${PRIV1_CIDR:-10.100.10.0/24}"
PRIV2_CIDR="${PRIV2_CIDR:-10.100.20.0/24}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS=(aws --region "$AWS_REGION")
# shellcheck source=common-tags.sh
source "$HERE/common-tags.sh"
log() { echo "$*" >&2; }
only() { grep -Eo "$1" | tail -1; }

AZS=($("${AWS[@]}" ec2 describe-availability-zones \
  --filters Name=state,Values=available \
  --query 'AvailabilityZones[?ZoneType==`availability-zone`].ZoneName' --output text))
AZ0="${AZS[0]}"; AZ1="${AZS[1]}"

VPC_ID="$("${AWS[@]}" ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${NAME_PREFIX}-vpc" \
  --query 'Vpcs[0].VpcId' --output text)"
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  log "==> create VPC ${VPC_CIDR}"
  VPC_ID="$("${AWS[@]}" ec2 create-vpc --cidr-block "$VPC_CIDR" --query Vpc.VpcId --output text)"
  "${AWS[@]}" ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=${NAME_PREFIX}-vpc"
else
  log "==> reuse VPC ${VPC_ID}"
fi
tag_ec2 "$VPC_ID"
"${AWS[@]}" ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
"${AWS[@]}" ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames

IGW_ID="$("${AWS[@]}" ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)"
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
  log "==> create IGW"
  IGW_ID="$("${AWS[@]}" ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
  "${AWS[@]}" ec2 create-tags --resources "$IGW_ID" --tags "Key=Name,Value=${NAME_PREFIX}-igw"
  "${AWS[@]}" ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
else
  log "==> reuse IGW ${IGW_ID}"
fi
tag_ec2 "$IGW_ID"

ensure_subnet() {
  local cidr="$1" az="$2" name="$3" id
  id="$("${AWS[@]}" ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" \
    --query 'Subnets[0].SubnetId' --output text)"
  if [[ -z "$id" || "$id" == "None" ]]; then
    id="$("${AWS[@]}" ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${cidr}" \
      --query 'Subnets[0].SubnetId' --output text)"
  fi
  if [[ -z "$id" || "$id" == "None" ]]; then
    log "    create ${name} ${cidr}"
    id="$("${AWS[@]}" ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
      --availability-zone "$az" --query Subnet.SubnetId --output text)"
    "${AWS[@]}" ec2 create-tags --resources "$id" --tags "Key=Name,Value=${name}"
  else
    log "    reuse ${name} ${id}"
  fi
  tag_ec2 "$id"
  echo "$id"
}

PUB1="$(ensure_subnet "$PUB1_CIDR" "$AZ0" "${NAME_PREFIX}-public-1" | only 'subnet-[a-f0-9]+')"
PUB2="$(ensure_subnet "$PUB2_CIDR" "$AZ1" "${NAME_PREFIX}-public-2" | only 'subnet-[a-f0-9]+')"
PRIV1="$(ensure_subnet "$PRIV1_CIDR" "$AZ0" "${NAME_PREFIX}-private-1" | only 'subnet-[a-f0-9]+')"
PRIV2="$(ensure_subnet "$PRIV2_CIDR" "$AZ1" "${NAME_PREFIX}-private-2" | only 'subnet-[a-f0-9]+')"
"${AWS[@]}" ec2 modify-subnet-attribute --subnet-id "$PUB1" --map-public-ip-on-launch
"${AWS[@]}" ec2 modify-subnet-attribute --subnet-id "$PUB2" --map-public-ip-on-launch
"${AWS[@]}" ec2 create-tags --resources "$PUB1" "$PUB2" --tags "Key=kubernetes.io/role/elb,Value=1" "${EC2_TAGS[@]}"
"${AWS[@]}" ec2 create-tags --resources "$PRIV1" "$PRIV2" --tags "Key=kubernetes.io/role/internal-elb,Value=1" "${EC2_TAGS[@]}"

ensure_rt() {
  local name="$1" id
  id="$("${AWS[@]}" ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [[ -z "$id" || "$id" == "None" ]]; then
    id="$("${AWS[@]}" ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)"
    "${AWS[@]}" ec2 create-tags --resources "$id" --tags "Key=Name,Value=${name}"
  fi
  tag_ec2 "$id"
  echo "$id"
}
ensure_default_route() {
  local rtb="$1"; shift
  local have
  have="$("${AWS[@]}" ec2 describe-route-tables --route-table-ids "$rtb" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].DestinationCidrBlock' --output text)"
  [[ -n "$have" && "$have" != "None" ]] && return 0
  "${AWS[@]}" ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 "$@" >/dev/null
}
ensure_assoc() {
  local rtb="$1" subnet="$2" have
  have="$("${AWS[@]}" ec2 describe-route-tables --route-table-ids "$rtb" \
    --query "RouteTables[0].Associations[?SubnetId=='${subnet}'].SubnetId" --output text)"
  [[ -n "$have" && "$have" != "None" ]] && return 0
  "${AWS[@]}" ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$subnet" >/dev/null
}

PUB_RT="$(ensure_rt "${NAME_PREFIX}-public-rt" | only 'rtb-[a-f0-9]+')"
ensure_default_route "$PUB_RT" --gateway-id "$IGW_ID"
ensure_assoc "$PUB_RT" "$PUB1"
ensure_assoc "$PUB_RT" "$PUB2"

NAT="$("${AWS[@]}" ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${NAME_PREFIX}-nat" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[?State==`available` || State==`pending`].NatGatewayId | [0]' --output text)"
if [[ -z "$NAT" || "$NAT" == "None" ]]; then
  log "==> create NAT + EIP"
  EIP="$("${AWS[@]}" ec2 allocate-address --domain vpc --query AllocationId --output text)"
  "${AWS[@]}" ec2 create-tags --resources "$EIP" --tags "Key=Name,Value=${NAME_PREFIX}-nat-eip" "${EC2_TAGS[@]}"
  NAT="$("${AWS[@]}" ec2 create-nat-gateway --subnet-id "$PUB1" --allocation-id "$EIP" \
    --query NatGateway.NatGatewayId --output text)"
  "${AWS[@]}" ec2 create-tags --resources "$NAT" --tags "Key=Name,Value=${NAME_PREFIX}-nat"
else
  log "==> reuse NAT ${NAT}"
fi
tag_ec2 "$NAT"
"${AWS[@]}" ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"

PRIV_RT="$(ensure_rt "${NAME_PREFIX}-private-rt" | only 'rtb-[a-f0-9]+')"
ensure_default_route "$PRIV_RT" --nat-gateway-id "$NAT"
ensure_assoc "$PRIV_RT" "$PRIV1"
ensure_assoc "$PRIV_RT" "$PRIV2"

jq --arg vpc "$VPC_ID" --arg priv "${PRIV1},${PRIV2}" --arg pub "${PUB1},${PUB2}" \
  '.VpcId=$vpc | .PrivateSubnetIds=$priv | .PublicSubnetIds=$pub' \
  "$HERE/parameters.json" > "$HERE/parameters.json.tmp"
mv "$HERE/parameters.json.tmp" "$HERE/parameters.json"

log "VpcId=$VPC_ID"
log "PrivateSubnetIds=${PRIV1},${PRIV2}"
log "PublicSubnetIds=${PUB1},${PUB2}"
log "Next: ./deploy.sh"
