#!/usr/bin/env bash
# =============================================================================
# TEST FIXTURE: Tear down the test RDS and its VPC
# =============================================================================
set -uo pipefail

REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
DB_NAME="${DB_NAME:-cdx-test-postgres-2}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }
ok()  { echo "[OK] $*"; }

# RDS instance
if aws rds describe-db-instances --db-instance-identifier "$DB_NAME" > /dev/null 2>&1; then
    log "Deleting RDS instance (takes a few min)..."
    aws rds delete-db-instance --db-instance-identifier "$DB_NAME" \
        --skip-final-snapshot --delete-automated-backups > /dev/null 2>&1 || true
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_NAME" 2>/dev/null || true
    ok "RDS deleted"
fi

# Subnet group
aws rds delete-db-subnet-group --db-subnet-group-name "${DB_NAME}-subnet-group" 2>/dev/null || true
ok "Subnet group deleted"

# VPC teardown
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${DB_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    # Delete any peering connections touching this VPC
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
    aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    ok "VPC deleted: $VPC_ID"
fi

ok "Test RDS teardown complete"
