#!/bin/bash
set -e
set -u

export AWS_PAGER="" 

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Function to add tags to a resource
add_tags() {
    local resource_arn=$1
    local resource_name=$2
    
    log "Adding tags to $resource_name..."
    aws resourcegroupstaggingapi tag-resources \
        --resource-arn-list "$resource_arn" \
        --tags "purpose=database-iam-jit,Name=${resource_name},created_by=cloudanix" \
        --region $AWS_REGION || {
            log "Warning: Failed to tag resource $resource_arn"
            return 1
        }
}

# Read AWS region and project name
read -p "Enter AWS Region [ap-south-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-ap-south-1}

read -p "Enter Project Name [jit-db]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-jit-db}

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

log "Starting resource discovery and tagging..."

# Find VPC by name tag
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' \
    --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    log "No VPC found with name ${PROJECT_NAME}-vpc. Please enter VPC ID:"
    read -p "VPC ID: " VPC_ID
fi

log "Found VPC: $VPC_ID"

# Tag VPC
add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:vpc/${VPC_ID}" "${PROJECT_NAME}-vpc"

# Find and tag subnets
log "Finding and tagging subnets..."
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[*].[SubnetId,Tags[?Key==`Name`].Value|[0]]' \
    --output text)

while IFS=$'\t' read -r subnet_id subnet_name; do
    if [ -n "$subnet_id" ]; then
        # If subnet doesn't have a name tag, create one based on whether it's public or private
        if [ -z "$subnet_name" ]; then
            # Check if subnet has a route to IGW (public) or NAT (private)
            ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
                --filters "Name=association.subnet-id,Values=${subnet_id}" \
                --query 'RouteTables[0].RouteTableId' \
                --output text)
            
            if aws ec2 describe-route-tables \
                --route-table-ids "$ROUTE_TABLE_ID" \
                --query 'RouteTables[0].Routes[?GatewayId!=`null`]' \
                --output text | grep -q "igw-"; then
                subnet_name="${PROJECT_NAME}-public"
            else
                subnet_name="${PROJECT_NAME}-private"
            fi
        fi
        add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:subnet/${subnet_id}" "$subnet_name"
    fi
done <<< "$SUBNETS"

# Find and tag security groups
log "Finding and tagging security groups..."
SECURITY_GROUPS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[*].[GroupId,GroupName]' \
    --output text)

while IFS=$'\t' read -r sg_id sg_name; do
    if [ -n "$sg_id" ]; then
        add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:security-group/${sg_id}" "${PROJECT_NAME}-${sg_name}"
    fi
done <<< "$SECURITY_GROUPS"

# Find and tag ECS Cluster
log "Finding and tagging ECS Cluster..."
ECS_CLUSTERS=$(aws ecs list-clusters --query 'clusterArns[]' --output text)
for cluster_arn in $ECS_CLUSTERS; do
    cluster_name=$(echo "$cluster_arn" | awk -F/ '{print $2}')
    if [[ $cluster_name == *"$PROJECT_NAME"* ]]; then
        aws ecs tag-resource \
            --resource-arn "$cluster_arn" \
            --tags "key=purpose,value=database-iam-jit" "key=Name,value=${PROJECT_NAME}-cluster" "key=created_by,value=cloudanix"
    fi
done

# Define specific repositories to tag
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server")

log "Tagging specified ECR repositories..."
for repo in "${REPOSITORIES[@]}"; do
    REPO_ARN=$(aws ecr describe-repositories --repository-names "$repo" \
        --query 'repositories[0].repositoryArn' --output text 2>/dev/null)

    if [ -n "$REPO_ARN" ] && [ "$REPO_ARN" != "None" ]; then
        aws ecr tag-resource --resource-arn "$REPO_ARN" \
            --tags "Key=Name,Value=${repo}" "Key=purpose,Value=database-iam-jit" "Key=created_by,Value=cloudanix" || \
            log "Warning: Failed to tag ECR repository $repo"
        log "Tagged ECR repository: $repo"
    else
        log "Warning: Repository $repo not found!"
    fi
done

# Find and tag Internet Gateway
log "Finding and tagging Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text)
if [ "$IGW_ID" != "None" ]; then
    add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:internet-gateway/${IGW_ID}" "${PROJECT_NAME}-igw"
fi

# Find and tag NAT Gateways
log "Finding and tagging NAT Gateways..."
NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NatGateways[*].[NatGatewayId]' \
    --output text)
for nat_id in $NAT_GATEWAYS; do
    if [ -n "$nat_id" ]; then
        add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:natgateway/${nat_id}" "${PROJECT_NAME}-nat"
    fi
done

# Find and tag Route Tables
log "Finding and tagging Route Tables..."
ROUTE_TABLES=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[*].RouteTableId' \
    --output text)
for rt_id in $ROUTE_TABLES; do
    if [ -n "$rt_id" ]; then
        add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:route-table/${rt_id}" "${PROJECT_NAME}-rt"
    fi
done

# Find and tag EFS File Systems
log "Finding and tagging EFS File Systems..."
EFS_SYSTEMS=$(aws efs describe-file-systems \
    --query 'FileSystems[*].[FileSystemId,Tags[?Key==`Name`].Value|[0]]' \
    --output text)
while IFS=$'\t' read -r efs_id efs_name; do
    if [ -n "$efs_id" ] && [[ "$efs_name" == *"$PROJECT_NAME"* ]]; then
        add_tags "arn:aws:elasticfilesystem:${AWS_REGION}:${ACCOUNT_ID}:file-system/${efs_id}" "${PROJECT_NAME}-efs"
    fi
done <<< "$EFS_SYSTEMS"

# Tag CloudWatch Log Groups
log "Tagging CloudWatch Log Groups..."
LOG_GROUPS=$(aws logs describe-log-groups \
    --log-group-name-prefix "/ecs/${PROJECT_NAME}" \
    --query 'logGroups[*].logGroupName' \
    --output text)
for log_group in $LOG_GROUPS; do
    aws logs tag-log-group \
        --log-group-name "$log_group" \
        --tags "purpose=database-iam-jit,created_by=cloudanix" || log "Warning: Failed to tag log group $log_group"
done

# Find and tag Secrets Manager secrets
log "Finding and tagging Secrets Manager secrets..."
SECRETS=$(aws secretsmanager list-secrets \
    --query 'SecretList[?Name==`CDX_SECRETS`].ARN' \
    --output text)
for secret_arn in $SECRETS; do
    if [ -n "$secret_arn" ] && [ "$secret_arn" != "None" ]; then
        add_tags "$secret_arn" "${PROJECT_NAME}-secret"
    fi
done

# Find and tag VPC Peering connections
log "Finding and tagging VPC Peering connections..."
PEERING_CONNECTIONS=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=${VPC_ID}" \
            "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' \
    --output text)

if [ -n "$PEERING_CONNECTIONS" ] && [ "$PEERING_CONNECTIONS" != "None" ]; then
    for PEERING_ID in $PEERING_CONNECTIONS; do
        # Get the accepter VPC ID for naming
        ACCEPTER_VPC_ID=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$PEERING_ID" \
            --query 'VpcPeeringConnections[0].AccepterVpcInfo.VpcId' \
            --output text)
        
        add_tags "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:vpc-peering-connection/${PEERING_ID}" \
                "${PROJECT_NAME}-peering-${ACCEPTER_VPC_ID}"
    done
fi

log "Tagging completed!"