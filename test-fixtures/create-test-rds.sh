#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Create a minimal private RDS in a dedicated VPC
# =============================================================================
# Provisions a small private PostgreSQL RDS in its own VPC so we can test the
# aws-jit-db onboarding scopes (onboard-new-account = unpeered VPC).
#
# Run in the target account (e.g. 214371877406), us-east-1.
#
# Usage:
#   ./create-test-rds.sh
#   VPC_CIDR=10.60.0.0/16 DB_NAME=cdx-test-postgres-2 ./create-test-rds.sh
#
# Outputs the values needed for the onboard flow:
#   DB_VPC_ID, DB_VPC_CIDR, DB_SECURITY_GROUP_IDS, RDS endpoint
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

DB_NAME="${DB_NAME:-cdx-test-postgres-2}"
VPC_CIDR="${VPC_CIDR:-10.60.0.0/16}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
DB_ENGINE="${DB_ENGINE:-postgres}"
DB_USER="${DB_USER:-cdxadmin}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[OK] $*"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Account: $ACCOUNT_ID | Region: $REGION | DB: $DB_NAME | CIDR: $VPC_CIDR"

AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)
VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)

# =============================================================================
# VPC + SUBNETS
# =============================================================================

log "Creating VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${DB_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${DB_NAME}-vpc},{Key=purpose,Value=cdx-jit-test}]" \
        --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
fi
ok "VPC: $VPC_ID"

create_subnet() {
    local cidr=$1 az=$2 name=$3
    local sid
    sid=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$sid" || "$sid" == "None" ]]; then
        sid=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name}]" \
            --query 'Subnet.SubnetId' --output text)
    fi
    echo "$sid"
}

SUB_1=$(create_subnet "${VPC_BASE}.1.0/24" "$AZ_1" "${DB_NAME}-subnet-1")
SUB_2=$(create_subnet "${VPC_BASE}.2.0/24" "$AZ_2" "${DB_NAME}-subnet-2")
ok "Subnets: $SUB_1, $SUB_2"

# =============================================================================
# RDS SECURITY GROUP (private — no ingress yet; onboard flow adds it)
# =============================================================================

SG_NAME="${DB_NAME}-rds-sg"
RDS_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$RDS_SG" || "$RDS_SG" == "None" ]]; then
    RDS_SG=$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description "Test RDS SG (private, JIT onboarding target)" --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME}]" \
        --query 'GroupId' --output text)
fi
ok "RDS SG: $RDS_SG"

# =============================================================================
# DB SUBNET GROUP
# =============================================================================

SUBNET_GROUP="${DB_NAME}-subnet-group"
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP" > /dev/null 2>&1; then
    aws rds create-db-subnet-group \
        --db-subnet-group-name "$SUBNET_GROUP" \
        --db-subnet-group-description "Test subnet group for $DB_NAME" \
        --subnet-ids "$SUB_1" "$SUB_2" > /dev/null
fi
ok "DB subnet group: $SUBNET_GROUP"

# =============================================================================
# RDS INSTANCE
# =============================================================================

RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_NAME" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null) || RDS_STATUS=""

if [[ -z "$RDS_STATUS" ]]; then
    log "Creating RDS instance (this takes ~5-10 min)..."
    aws rds create-db-instance \
        --db-instance-identifier "$DB_NAME" \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --engine "$DB_ENGINE" \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASSWORD" \
        --allocated-storage 20 \
        --db-subnet-group-name "$SUBNET_GROUP" \
        --vpc-security-group-ids "$RDS_SG" \
        --no-publicly-accessible \
        --backup-retention-period 0 \
        --enable-iam-database-authentication \
        --tags "Key=purpose,Value=cdx-jit-test" > /dev/null
    log "Waiting for RDS to become available..."
    aws rds wait db-instance-available --db-instance-identifier "$DB_NAME"
    ok "RDS available"
else
    ok "RDS exists (status: $RDS_STATUS)"
fi

RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_NAME" \
    --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null)

# =============================================================================
# OUTPUT
# =============================================================================

echo ""
echo "============================================================"
echo "  Test RDS ready — values for aws-jit-db onboarding:"
echo "============================================================"
echo "  DB Account            : $ACCOUNT_ID"
echo "  DB_VPC_ID             : $VPC_ID"
echo "  DB_VPC_CIDR           : $VPC_CIDR"
echo "  DB_SECURITY_GROUP_IDS : $RDS_SG"
echo "  RDS endpoint          : ${RDS_ENDPOINT:-<pending>}"
echo "  RDS identifier        : $DB_NAME"
echo "  Master user           : $DB_USER"
echo "  Master password       : $DB_PASSWORD"
echo "  Subnets               : $SUB_1, $SUB_2"
echo "============================================================"
echo ""
echo "  For onboard-new-account (unpeered): use DB_VPC_ID + DB_VPC_CIDR + DB_SECURITY_GROUP_IDS"
echo "  For onboard-peered: only if this VPC is already peered to the hub"
