#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Variables (these should match your creation script)
PROJECT_NAME="cdx-jit-db"
AWS_REGION="ap-south-1"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
SECRET_NAME="CDX_SECRETS"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"

# Function to delete if exists
delete_if_exists() {
    local cmd=$1
    local id=$2
    local resource_type=$3
    if [ -n "$id" ] && [ "$id" != "None" ]; then
        log "Deleting $resource_type: $id"
        $cmd || log "Failed to delete $resource_type $id or already deleted"
    fi
}

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    log "Found VPC: $VPC_ID"
    
    # Get dependent resource IDs
    ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-efs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[0].NatGatewayId' --output text)
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
    
    # Get subnet IDs
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
    
    # Get ALL route tables (including main route table)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].RouteTableId' --output text)
fi

# 1. Delete ECS Services and Tasks
log "Cleaning up ECS resources..."
if aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$ECS_CLUSTER_NAME"; then
    # Update services to 0 tasks
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxyserver --desired-count 0 || true
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxysql --desired-count 0 || true
    log "Waiting for tasks to drain..."
    sleep 30
    
    # Delete services
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxyserver --force || true
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxysql --force || true
    
    # Delete cluster
    aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME || true
fi

# 2. Delete Service Discovery Namespace
NAMESPACE_ID=$(aws servicediscovery list-namespaces --query 'Namespaces[?Name==`proxysql-proxyserver`].Id' --output text)
if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    log "Deleting Service Discovery resources..."
    SERVICE_IDS=$(aws servicediscovery list-services --filters "Name=namespace-id,Values=$NAMESPACE_ID" --query 'Services[*].Id' --output text)
    for SERVICE_ID in $SERVICE_IDS; do
        aws servicediscovery delete-service --id $SERVICE_ID || true
    done
    aws servicediscovery delete-namespace --id $NAMESPACE_ID || true
fi

# 3. Delete EFS resources
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" --output text)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    log "Deleting EFS resources..."
    # Delete mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'MountTargets[*].MountTargetId' --output text)
    for MT_ID in $MOUNT_TARGETS; do
        aws efs delete-mount-target --mount-target-id $MT_ID || true
    done
    log "Waiting for mount targets to be deleted..."
    sleep 30
    
    # Delete access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id $EFS_ID --query 'AccessPoints[*].AccessPointId' --output text)
    for AP_ID in $ACCESS_POINTS; do
        aws efs delete-access-point --access-point-id $AP_ID || true
    done
    
    # Delete file system
    aws efs delete-file-system --file-system-id $EFS_ID || true
fi

# 4. Delete CloudWatch Log Groups
log "Deleting CloudWatch Log Groups..."
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_1 || true
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_2 || true

# 5. Delete Secrets Manager Secret
log "Deleting Secrets Manager Secret..."
aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery || true

# 6. Delete S3 Bucket
log "Deleting S3 Bucket..."
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT_NAME}-')].Name" --output text)
if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    aws s3 rm s3://$BUCKET_NAME --recursive || true
    aws s3api delete-bucket --bucket $BUCKET_NAME || true
fi

# 7. Delete IAM Roles and Policies
log "Cleaning up IAM resources..."
# Detach policies from ECSTaskRole
aws iam detach-role-policy --role-name cdx-ECSTaskRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam detach-role-policy --role-name cdx-ECSTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
aws iam detach-role-policy --role-name cdx-ECSTaskRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || true

# Delete custom policies
for POLICY_NAME in "cdx-ECSSecretsAccessPolicy" "cdx-ECSRDSAssumeRolePolicy" "cdx-EFSAccessPolicy" "cdx-CloudWatchLogsPolicy" "cdx-S3AccessPolicy"; do
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
    if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
        aws iam detach-role-policy --role-name ECSTaskRole --policy-arn $POLICY_ARN || true
        aws iam delete-policy --policy-arn $POLICY_ARN || true
    fi
done

# Delete role
aws iam delete-role --role-name ECSTaskRole || true

# 8. Clean up VPC Resources
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log "Cleaning up VPC resources..."
    
    # Delete NAT Gateway first
    if [ -n "$NAT_GATEWAY_ID" ] && [ "$NAT_GATEWAY_ID" != "None" ]; then
        log "Deleting NAT Gateway..."
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GATEWAY_ID
        log "Waiting for NAT Gateway to be deleted..."
        sleep 30
    fi
    
    # Delete Elastic IP
    ELASTIC_IP_ID=$(aws ec2 describe-addresses --query 'Addresses[0].AllocationId' --output text)
    if [ -n "$ELASTIC_IP_ID" ] && [ "$ELASTIC_IP_ID" != "None" ]; then
        log "Deleting Elastic IP..."
        aws ec2 release-address --allocation-id $ELASTIC_IP_ID || true
    fi
    
    # Remove route table associations first
    log "Removing route table associations..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id $ASSOC_ID || true
        done
    done
    
    # Delete non-main route tables
    log "Deleting route tables..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        # Skip main route table
        if ! aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[0].Main' --output text | grep -q "True"; then
            aws ec2 delete-route-table --route-table-id $RT_ID || true
        fi
    done
    
    # Delete subnets
    log "Deleting subnets..."
    for SUBNET_ID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id $SUBNET_ID || true
    done
    
    # Detach and delete internet gateway
    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        log "Deleting Internet Gateway..."
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
    fi
    
    # Delete security groups
    log "Deleting security groups..."
    if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $ECS_SG_ID || true
    fi
    if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $EFS_SG_ID || true
    fi
    
    # Finally delete VPC
    log "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id $VPC_ID || true
fi

log "Cleanup complete!"
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Variables (these should match your creation script)
PROJECT_NAME="jit-db"
AWS_REGION="ap-south-1"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
SECRET_NAME="CDX_SECRETS_v1"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"

# Function to delete if exists
delete_if_exists() {
    local cmd=$1
    local id=$2
    local resource_type=$3
    if [ -n "$id" ] && [ "$id" != "None" ]; then
        log "Deleting $resource_type: $id"
        $cmd || log "Failed to delete $resource_type $id or already deleted"
    fi
}

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    log "Found VPC: $VPC_ID"
    
    # Get dependent resource IDs
    ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-efs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[0].NatGatewayId' --output text)
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
    
    # Get subnet IDs
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
    
    # Get ALL route tables (including main route table)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].RouteTableId' --output text)
fi

# 1. Delete ECS Services and Tasks
log "Cleaning up ECS resources..."
if aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$ECS_CLUSTER_NAME"; then
    # Update services to 0 tasks
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxyserver --desired-count 0 || true
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxysql --desired-count 0 || true
    log "Waiting for tasks to drain..."
    sleep 30
    
    # Delete services
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxyserver --force || true
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxysql --force || true
    
    # Delete cluster
    aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME || true
fi

# 2. Delete Service Discovery Namespace
NAMESPACE_ID=$(aws servicediscovery list-namespaces --query 'Namespaces[?Name==`proxysql-proxyserver`].Id' --output text)
if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    log "Deleting Service Discovery resources..."
    SERVICE_IDS=$(aws servicediscovery list-services --filters "Name=namespace-id,Values=$NAMESPACE_ID" --query 'Services[*].Id' --output text)
    for SERVICE_ID in $SERVICE_IDS; do
        aws servicediscovery delete-service --id $SERVICE_ID || true
    done
    aws servicediscovery delete-namespace --id $NAMESPACE_ID || true
fi

# 3. Delete EFS resources
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" --output text)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    log "Deleting EFS resources..."
    # Delete mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'MountTargets[*].MountTargetId' --output text)
    for MT_ID in $MOUNT_TARGETS; do
        aws efs delete-mount-target --mount-target-id $MT_ID || true
    done
    log "Waiting for mount targets to be deleted..."
    sleep 30
    
    # Delete access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id $EFS_ID --query 'AccessPoints[*].AccessPointId' --output text)
    for AP_ID in $ACCESS_POINTS; do
        aws efs delete-access-point --access-point-id $AP_ID || true
    done
    
    # Delete file system
    aws efs delete-file-system --file-system-id $EFS_ID || true
fi

# 4. Delete CloudWatch Log Groups
log "Deleting CloudWatch Log Groups..."
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_1 || true
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_2 || true

# 5. Delete Secrets Manager Secret
log "Deleting Secrets Manager Secret..."
aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery || true

# 6. Delete S3 Bucket
log "Deleting S3 Bucket..."
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT_NAME}-')].Name" --output text)
if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    aws s3 rm s3://$BUCKET_NAME --recursive || true
    aws s3api delete-bucket --bucket $BUCKET_NAME || true
fi

# 7. Delete IAM Roles and Policies
log "Cleaning up IAM resources..."
# Detach policies from ECSTaskRole
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || true

# Delete custom policies
for POLICY_NAME in "ECSSecretsAccessPolicy" "ECSRDSAssumeRolePolicy" "EFSAccessPolicy"; do
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
    if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
        aws iam detach-role-policy --role-name ECSTaskRole --policy-arn $POLICY_ARN || true
        aws iam delete-policy --policy-arn $POLICY_ARN || true
    fi
done

# Delete role
aws iam delete-role --role-name ECSTaskRole || true

# 8. Clean up VPC Resources
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log "Cleaning up VPC resources..."
    
    # Delete NAT Gateway first
    if [ -n "$NAT_GATEWAY_ID" ] && [ "$NAT_GATEWAY_ID" != "None" ]; then
        log "Deleting NAT Gateway..."
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GATEWAY_ID
        log "Waiting for NAT Gateway to be deleted..."
        sleep 30
    fi
    
    # Delete Elastic IP
    ELASTIC_IP_ID=$(aws ec2 describe-addresses --query 'Addresses[0].AllocationId' --output text)
    if [ -n "$ELASTIC_IP_ID" ] && [ "$ELASTIC_IP_ID" != "None" ]; then
        log "Deleting Elastic IP..."
        aws ec2 release-address --allocation-id $ELASTIC_IP_ID || true
    fi
    
    # Remove route table associations first
    log "Removing route table associations..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id $ASSOC_ID || true
        done
    done
    
    # Delete non-main route tables
    log "Deleting route tables..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        # Skip main route table
        if ! aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[0].Main' --output text | grep -q "True"; then
            aws ec2 delete-route-table --route-table-id $RT_ID || true
        fi
    done
    
    # Delete subnets
    log "Deleting subnets..."
    for SUBNET_ID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id $SUBNET_ID || true
    done
    
    # Detach and delete internet gateway
    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        log "Deleting Internet Gateway..."
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
    fi
    
    # Delete security groups
    log "Deleting security groups..."
    if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $ECS_SG_ID || true
    fi
    if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $EFS_SG_ID || true
    fi
    
    # Finally delete VPC
    log "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id $VPC_ID || true
fi

log "Cleanup complete!"#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Variables (these should match your creation script)
PROJECT_NAME="jit-db"
AWS_REGION="ap-south-1"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
SECRET_NAME="CDX_SECRETS_v1.0.1"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"

# Function to delete if exists
delete_if_exists() {
    local cmd=$1
    local id=$2
    local resource_type=$3
    if [ -n "$id" ] && [ "$id" != "None" ]; then
        log "Deleting $resource_type: $id"
        $cmd || log "Failed to delete $resource_type $id or already deleted"
    fi
}

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    log "Found VPC: $VPC_ID"
    
    # Get dependent resource IDs
    ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-efs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[0].NatGatewayId' --output text)
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
    
    # Get subnet IDs
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
    
    # Get ALL route tables (including main route table)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].RouteTableId' --output text)
fi

# 1. Delete ECS Services and Tasks
log "Cleaning up ECS resources..."
if aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$ECS_CLUSTER_NAME"; then
    # Update services to 0 tasks
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxyserver --desired-count 0 || true
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxysql --desired-count 0 || true
    log "Waiting for tasks to drain..."
    sleep 30
    
    # Delete services
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxyserver --force || true
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxysql --force || true
    
    # Delete cluster
    aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME || true
fi

# 2. Delete Service Discovery Namespace
NAMESPACE_ID=$(aws servicediscovery list-namespaces --query 'Namespaces[?Name==`proxysql-proxyserver`].Id' --output text)
if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    log "Deleting Service Discovery resources..."
    SERVICE_IDS=$(aws servicediscovery list-services --filters "Name=namespace-id,Values=$NAMESPACE_ID" --query 'Services[*].Id' --output text)
    for SERVICE_ID in $SERVICE_IDS; do
        aws servicediscovery delete-service --id $SERVICE_ID || true
    done
    aws servicediscovery delete-namespace --id $NAMESPACE_ID || true
fi

# 3. Delete EFS resources
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" --output text)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    log "Deleting EFS resources..."
    # Delete mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'MountTargets[*].MountTargetId' --output text)
    for MT_ID in $MOUNT_TARGETS; do
        aws efs delete-mount-target --mount-target-id $MT_ID || true
    done
    log "Waiting for mount targets to be deleted..."
    sleep 30
    
    # Delete access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id $EFS_ID --query 'AccessPoints[*].AccessPointId' --output text)
    for AP_ID in $ACCESS_POINTS; do
        aws efs delete-access-point --access-point-id $AP_ID || true
    done
    
    # Delete file system
    aws efs delete-file-system --file-system-id $EFS_ID || true
fi

# 4. Delete CloudWatch Log Groups
log "Deleting CloudWatch Log Groups..."
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_1 || true
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_2 || true

# 5. Delete Secrets Manager Secret
log "Deleting Secrets Manager Secret..."
aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery || true

# 6. Delete S3 Bucket
log "Deleting S3 Bucket..."
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT_NAME}-')].Name" --output text)
if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    aws s3 rm s3://$BUCKET_NAME --recursive || true
    aws s3api delete-bucket --bucket $BUCKET_NAME || true
fi

# 7. Delete IAM Roles and Policies
log "Cleaning up IAM resources..."
# Detach policies from ECSTaskRole
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || true

# Delete custom policies
for POLICY_NAME in "ECSSecretsAccessPolicy" "ECSRDSAssumeRolePolicy" "EFSAccessPolicy"; do
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
    if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
        aws iam detach-role-policy --role-name ECSTaskRole --policy-arn $POLICY_ARN || true
        aws iam delete-policy --policy-arn $POLICY_ARN || true
    fi
done

# Delete role
aws iam delete-role --role-name ECSTaskRole || true

# 8. Clean up VPC Resources
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log "Cleaning up VPC resources..."
    
    # Delete NAT Gateway first
    if [ -n "$NAT_GATEWAY_ID" ] && [ "$NAT_GATEWAY_ID" != "None" ]; then
        log "Deleting NAT Gateway..."
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GATEWAY_ID
        log "Waiting for NAT Gateway to be deleted..."
        sleep 30
    fi
    
    # Delete Elastic IP
    ELASTIC_IP_ID=$(aws ec2 describe-addresses --query 'Addresses[0].AllocationId' --output text)
    if [ -n "$ELASTIC_IP_ID" ] && [ "$ELASTIC_IP_ID" != "None" ]; then
        log "Deleting Elastic IP..."
        aws ec2 release-address --allocation-id $ELASTIC_IP_ID || true
    fi
    
    # Remove route table associations first
    log "Removing route table associations..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id $ASSOC_ID || true
        done
    done
    
    # Delete non-main route tables
    log "Deleting route tables..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        # Skip main route table
        if ! aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[0].Main' --output text | grep -q "True"; then
            aws ec2 delete-route-table --route-table-id $RT_ID || true
        fi
    done
    
    # Delete subnets
    log "Deleting subnets..."
    for SUBNET_ID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id $SUBNET_ID || true
    done
    
    # Detach and delete internet gateway
    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        log "Deleting Internet Gateway..."
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
    fi
    
    # Delete security groups
    log "Deleting security groups..."
    if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $ECS_SG_ID || true
    fi
    if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $EFS_SG_ID || true
    fi
    
    # Finally delete VPC
    log "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id $VPC_ID || true
fi

log "Cleanup complete!"#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Variables (these should match your creation script)
PROJECT_NAME="jit-db"
AWS_REGION="ap-south-1"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
SECRET_NAME="CDX_SECRETS_v1.0.1"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"

# Function to delete if exists
delete_if_exists() {
    local cmd=$1
    local id=$2
    local resource_type=$3
    if [ -n "$id" ] && [ "$id" != "None" ]; then
        log "Deleting $resource_type: $id"
        $cmd || log "Failed to delete $resource_type $id or already deleted"
    fi
}

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    log "Found VPC: $VPC_ID"
    
    # Get dependent resource IDs
    ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-efs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[0].NatGatewayId' --output text)
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
    
    # Get subnet IDs
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
    
    # Get ALL route tables (including main route table)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].RouteTableId' --output text)
fi

# 1. Delete ECS Services and Tasks
log "Cleaning up ECS resources..."
if aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$ECS_CLUSTER_NAME"; then
    # Update services to 0 tasks
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxyserver --desired-count 0 || true
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxysql --desired-count 0 || true
    log "Waiting for tasks to drain..."
    sleep 30
    
    # Delete services
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxyserver --force || true
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxysql --force || true
    
    # Delete cluster
    aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME || true
fi

# 2. Delete Service Discovery Namespace
NAMESPACE_ID=$(aws servicediscovery list-namespaces --query 'Namespaces[?Name==`proxysql-proxyserver`].Id' --output text)
if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    log "Deleting Service Discovery resources..."
    SERVICE_IDS=$(aws servicediscovery list-services --filters "Name=namespace-id,Values=$NAMESPACE_ID" --query 'Services[*].Id' --output text)
    for SERVICE_ID in $SERVICE_IDS; do
        aws servicediscovery delete-service --id $SERVICE_ID || true
    done
    aws servicediscovery delete-namespace --id $NAMESPACE_ID || true
fi

# 3. Delete EFS resources
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" --output text)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    log "Deleting EFS resources..."
    # Delete mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'MountTargets[*].MountTargetId' --output text)
    for MT_ID in $MOUNT_TARGETS; do
        aws efs delete-mount-target --mount-target-id $MT_ID || true
    done
    log "Waiting for mount targets to be deleted..."
    sleep 30
    
    # Delete access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id $EFS_ID --query 'AccessPoints[*].AccessPointId' --output text)
    for AP_ID in $ACCESS_POINTS; do
        aws efs delete-access-point --access-point-id $AP_ID || true
    done
    
    # Delete file system
    aws efs delete-file-system --file-system-id $EFS_ID || true
fi

# 4. Delete CloudWatch Log Groups
log "Deleting CloudWatch Log Groups..."
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_1 || true
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_2 || true

# 5. Delete Secrets Manager Secret
log "Deleting Secrets Manager Secret..."
aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery || true

# 6. Delete S3 Bucket
log "Deleting S3 Bucket..."
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT_NAME}-')].Name" --output text)
if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    aws s3 rm s3://$BUCKET_NAME --recursive || true
    aws s3api delete-bucket --bucket $BUCKET_NAME || true
fi

# 7. Delete IAM Roles and Policies
log "Cleaning up IAM resources..."
# Detach policies from ECSTaskRole
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || true

# Delete custom policies
for POLICY_NAME in "ECSSecretsAccessPolicy" "ECSRDSAssumeRolePolicy" "EFSAccessPolicy"; do
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
    if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
        aws iam detach-role-policy --role-name ECSTaskRole --policy-arn $POLICY_ARN || true
        aws iam delete-policy --policy-arn $POLICY_ARN || true
    fi
done

# Delete role
aws iam delete-role --role-name ECSTaskRole || true

# 8. Clean up VPC Resources
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log "Cleaning up VPC resources..."
    
    # Delete NAT Gateway first
    if [ -n "$NAT_GATEWAY_ID" ] && [ "$NAT_GATEWAY_ID" != "None" ]; then
        log "Deleting NAT Gateway..."
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GATEWAY_ID
        log "Waiting for NAT Gateway to be deleted..."
        sleep 30
    fi
    
    # Delete Elastic IP
    ELASTIC_IP_ID=$(aws ec2 describe-addresses --query 'Addresses[0].AllocationId' --output text)
    if [ -n "$ELASTIC_IP_ID" ] && [ "$ELASTIC_IP_ID" != "None" ]; then
        log "Deleting Elastic IP..."
        aws ec2 release-address --allocation-id $ELASTIC_IP_ID || true
    fi
    
    # Remove route table associations first
    log "Removing route table associations..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id $ASSOC_ID || true
        done
    done
    
    # Delete non-main route tables
    log "Deleting route tables..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        # Skip main route table
        if ! aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[0].Main' --output text | grep -q "True"; then
            aws ec2 delete-route-table --route-table-id $RT_ID || true
        fi
    done
    
    # Delete subnets
    log "Deleting subnets..."
    for SUBNET_ID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id $SUBNET_ID || true
    done
    
    # Detach and delete internet gateway
    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        log "Deleting Internet Gateway..."
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
    fi
    
    # Delete security groups
    log "Deleting security groups..."
    if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $ECS_SG_ID || true
    fi
    if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $EFS_SG_ID || true
    fi
    
    # Finally delete VPC
    log "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id $VPC_ID || true
fi

log "Cleanup complete!"#!/bin/bash
set -e
set -u

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Variables (these should match your creation script)
PROJECT_NAME="jit-db"
AWS_REGION="ap-south-1"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster"
SECRET_NAME="CDX_SECRETS_v1.0.1"
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"

# Function to delete if exists
delete_if_exists() {
    local cmd=$1
    local id=$2
    local resource_type=$3
    if [ -n "$id" ] && [ "$id" != "None" ]; then
        log "Deleting $resource_type: $id"
        $cmd || log "Failed to delete $resource_type $id or already deleted"
    fi
}

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    log "Found VPC: $VPC_ID"
    
    # Get dependent resource IDs
    ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PROJECT_NAME}-efs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
    NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[0].NatGatewayId' --output text)
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
    
    # Get subnet IDs
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
    
    # Get ALL route tables (including main route table)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].RouteTableId' --output text)
fi

# 1. Delete ECS Services and Tasks
log "Cleaning up ECS resources..."
if aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$ECS_CLUSTER_NAME"; then
    # Update services to 0 tasks
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxyserver --desired-count 0 || true
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service proxysql --desired-count 0 || true
    log "Waiting for tasks to drain..."
    sleep 30
    
    # Delete services
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxyserver --force || true
    aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service proxysql --force || true
    
    # Delete cluster
    aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME || true
fi

# 2. Delete Service Discovery Namespace
NAMESPACE_ID=$(aws servicediscovery list-namespaces --query 'Namespaces[?Name==`proxysql-proxyserver`].Id' --output text)
if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    log "Deleting Service Discovery resources..."
    SERVICE_IDS=$(aws servicediscovery list-services --filters "Name=namespace-id,Values=$NAMESPACE_ID" --query 'Services[*].Id' --output text)
    for SERVICE_ID in $SERVICE_IDS; do
        aws servicediscovery delete-service --id $SERVICE_ID || true
    done
    aws servicediscovery delete-namespace --id $NAMESPACE_ID || true
fi

# 3. Delete EFS resources
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" --output text)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    log "Deleting EFS resources..."
    # Delete mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'MountTargets[*].MountTargetId' --output text)
    for MT_ID in $MOUNT_TARGETS; do
        aws efs delete-mount-target --mount-target-id $MT_ID || true
    done
    log "Waiting for mount targets to be deleted..."
    sleep 30
    
    # Delete access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id $EFS_ID --query 'AccessPoints[*].AccessPointId' --output text)
    for AP_ID in $ACCESS_POINTS; do
        aws efs delete-access-point --access-point-id $AP_ID || true
    done
    
    # Delete file system
    aws efs delete-file-system --file-system-id $EFS_ID || true
fi

# 4. Delete CloudWatch Log Groups
log "Deleting CloudWatch Log Groups..."
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_1 || true
aws logs delete-log-group --log-group-name $LOG_GROUP_NAME_2 || true

# 5. Delete Secrets Manager Secret
log "Deleting Secrets Manager Secret..."
aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery || true

# 6. Delete S3 Bucket
log "Deleting S3 Bucket..."
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PROJECT_NAME}-')].Name" --output text)
if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    aws s3 rm s3://$BUCKET_NAME --recursive || true
    aws s3api delete-bucket --bucket $BUCKET_NAME || true
fi

# 7. Delete IAM Roles and Policies
log "Cleaning up IAM resources..."
# Detach policies from ECSTaskRole
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
aws iam detach-role-policy --role-name ECSTaskRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || true

# Delete custom policies
for POLICY_NAME in "ECSSecretsAccessPolicy" "ECSRDSAssumeRolePolicy" "EFSAccessPolicy"; do
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
    if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
        aws iam detach-role-policy --role-name ECSTaskRole --policy-arn $POLICY_ARN || true
        aws iam delete-policy --policy-arn $POLICY_ARN || true
    fi
done

# Delete role
aws iam delete-role --role-name ECSTaskRole || true

# 8. Clean up VPC Resources
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log "Cleaning up VPC resources..."
    
    # Delete NAT Gateway first
    if [ -n "$NAT_GATEWAY_ID" ] && [ "$NAT_GATEWAY_ID" != "None" ]; then
        log "Deleting NAT Gateway..."
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GATEWAY_ID
        log "Waiting for NAT Gateway to be deleted..."
        sleep 30
    fi
    
    # Delete Elastic IP
    ELASTIC_IP_ID=$(aws ec2 describe-addresses --query 'Addresses[0].AllocationId' --output text)
    if [ -n "$ELASTIC_IP_ID" ] && [ "$ELASTIC_IP_ID" != "None" ]; then
        log "Deleting Elastic IP..."
        aws ec2 release-address --allocation-id $ELASTIC_IP_ID || true
    fi
    
    # Remove route table associations first
    log "Removing route table associations..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id $ASSOC_ID || true
        done
    done
    
    # Delete non-main route tables
    log "Deleting route tables..."
    for RT_ID in $ROUTE_TABLE_IDS; do
        # Skip main route table
        if ! aws ec2 describe-route-tables --route-table-id $RT_ID --query 'RouteTables[0].Associations[0].Main' --output text | grep -q "True"; then
            aws ec2 delete-route-table --route-table-id $RT_ID || true
        fi
    done
    
    # Delete subnets
    log "Deleting subnets..."
    for SUBNET_ID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id $SUBNET_ID || true
    done
    
    # Detach and delete internet gateway
    if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        log "Deleting Internet Gateway..."
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
    fi
    
    # Delete security groups
    log "Deleting security groups..."
    if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $ECS_SG_ID || true
    fi
    if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id $EFS_SG_ID || true
    fi
    
    # Finally delete VPC
    log "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id $VPC_ID || true
fi

log "Cleanup complete!"