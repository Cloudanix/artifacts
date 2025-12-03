#!/bin/bash
set -e  # Exit on error
set -u  # Treat unset variables as errors

# Function to handle errors
handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code"
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    while true; do
        read -p "$prompt (y/n) [$default_value]: " yn
        yn=${yn:-$default_value}
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

prompt_for_confirmation() {
    local resource_type="$1"
    read -p "Are you sure you want to delete the $resource_type resources? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        log "Skipping deletion of $resource_type resources."
        return 1
    fi
    return 0
}

# AWS Configuration
log "=== JIT Account Infrastructure Cleanup - Additional VPC ==="
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
export AWS_REGION
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
SETUP_NUMBER=$(prompt_with_default "Enter the setup number to cleanup" "2")

# Ask about DAM cleanup
echo ""
CLEANUP_DAM=false
if prompt_yes_no "Was DAM (Database Activity Monitoring) enabled in setup #${SETUP_NUMBER}?" "n"; then
    CLEANUP_DAM=true
    echo "DAM resources will be included in cleanup"
else
    echo "Only ProxySQL resources will be cleaned up"
fi

PROJECT_NAME="cdx-jit-db"
ECS_CLUSTER_NAME="${PROJECT_NAME}-cluster-${SETUP_NUMBER}"
NAMESPACE_NAME="proxysql-proxyserver-${SETUP_NUMBER}"

# Resource names based on setup number
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver-${SETUP_NUMBER}"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql-${SETUP_NUMBER}"
LOG_GROUP_NAME_3="/ecs/${PROJECT_NAME}/query-logging-${SETUP_NUMBER}"

# DAM-specific log groups
if [ "$CLEANUP_DAM" = true ]; then
    LOG_GROUP_NAME_4="/ecs/${PROJECT_NAME}/dam-server-${SETUP_NUMBER}"
    LOG_GROUP_NAME_5="/ecs/${PROJECT_NAME}/postgresql-${SETUP_NUMBER}"
fi

SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name" "CDX_SECRETS")
BUCKET_NAME=$(prompt_with_default "S3 bucket name" "cdx-jit-db-logs")

log "Cleanup configuration:"
log "  Setup Number: $SETUP_NUMBER"
log "  AWS Region: $AWS_REGION"
log "  ECS Cluster: $ECS_CLUSTER_NAME"
log "  Namespace: $NAMESPACE_NAME"
log "  S3 Bucket: $BUCKET_NAME"
log "  Secret Name: $SECRET_NAME"
log "  Cleanup DAM: $CLEANUP_DAM"

if ! prompt_for_confirmation "all JIT-DB for setup #$SETUP_NUMBER"; then
    log "Cleanup aborted."
    exit 0
fi

# Step 1: Delete ECS Services
log "Step 1: Deleting ECS Services..."
if aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null | grep -q "ACTIVE"; then
    # Define core services
    SERVICES=("proxysql" "proxyserver" "query-logging")
    
    # Add DAM services if cleanup is enabled
    if [ "$CLEANUP_DAM" = true ]; then
        SERVICES+=("dam-server" "postgresql")
    fi
    
    for SERVICE_NAME in "${SERVICES[@]}"; do
        if aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" --query "services[?status=='ACTIVE']" --output text 2>/dev/null | grep -q "$SERVICE_NAME"; then
            log "Updating service $SERVICE_NAME to 0 desired count..."
            aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count 0 || true
            
            log "Waiting for service $SERVICE_NAME to scale down..."
            aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" || true
            
            log "Deleting service $SERVICE_NAME..."
            aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" --force
        else
            log "Service $SERVICE_NAME not found, skipping."
        fi
    done
    
    # Wait for services to be deleted
    log "Waiting for services to be deleted..."
    sleep 30
else
    log "ECS Cluster $ECS_CLUSTER_NAME not found, skipping service deletion."
fi

# Step 2: Delete ECS Cluster
log "Step 2: Deleting ECS Cluster..."
if aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null | grep -q "ACTIVE"; then
    aws ecs delete-cluster --cluster "$ECS_CLUSTER_NAME"
    log "ECS Cluster $ECS_CLUSTER_NAME deleted."
else
    log "ECS Cluster $ECS_CLUSTER_NAME not found, skipping."
fi

# Step 3: Delete ECS Task Definitions
log "Step 3: Deleting ECS Task Definitions..."
TASK_FAMILIES=(
    "proxyserver-task-${SETUP_NUMBER}"
    "proxysql-${SETUP_NUMBER}"
    "query-logging-task-${SETUP_NUMBER}"
)

# Add DAM task families if cleanup is enabled
if [ "$CLEANUP_DAM" = true ]; then
    TASK_FAMILIES+=(
        "dam-server-task-${SETUP_NUMBER}"
        "postgresql-task-${SETUP_NUMBER}"
    )
fi

for FAMILY in "${TASK_FAMILIES[@]}"; do
    # Get all active task definition revisions
    TASK_DEFINITIONS=$(aws ecs list-task-definitions --family-prefix "$FAMILY" --status ACTIVE --query "taskDefinitionArns" --output text)
    
    if [ -n "$TASK_DEFINITIONS" ]; then
        for TASK_DEF in $TASK_DEFINITIONS; do
            log "Deregistering task definition $TASK_DEF..."
            aws ecs deregister-task-definition --task-definition "$TASK_DEF"
        done
    else
        log "No task definitions found for family $FAMILY"
    fi
done

# Step 4: Delete Service Connect Namespace
log "Step 4: Deleting Service Connect Namespace..."
NAMESPACE_ID=$(aws servicediscovery list-namespaces --query "Namespaces[?Name=='$NAMESPACE_NAME'].Id" --output text)

if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    # First get and delete all services in the namespace
    SERVICES=$(aws servicediscovery list-services --filters Name=NAMESPACE_ID,Values="$NAMESPACE_ID" --query "Services[].Id" --output text)
    
    if [ -n "$SERVICES" ]; then
        for SERVICE_ID in $SERVICES; do
            # Delete all service instances first
            INSTANCES=$(aws servicediscovery list-instances --service-id "$SERVICE_ID" --query "Instances[].Id" --output text)
            for INSTANCE_ID in $INSTANCES; do
                log "Deregistering service instance $INSTANCE_ID..."
                aws servicediscovery deregister-instance --service-id "$SERVICE_ID" --instance-id "$INSTANCE_ID" || true
            done
            
            log "Deleting service $SERVICE_ID from namespace..."
            aws servicediscovery delete-service --id "$SERVICE_ID" || true
        done
    fi
    
    log "Deleting namespace $NAMESPACE_NAME..."
    # Namespaces can take time to delete, so we'll try up to 3 times with delays
    attempt=1
    max_attempts=3
    wait_time=30
    
    while [ $attempt -le $max_attempts ]; do
        if aws servicediscovery delete-namespace --id "$NAMESPACE_ID" 2>/dev/null; then
            log "Namespace deleted successfully."
            break
        else
            log "Attempt $attempt of $max_attempts, waiting ${wait_time} seconds..."
            sleep $wait_time
            attempt=$((attempt + 1))
        fi
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log "Warning: Failed to delete namespace after $max_attempts attempts. It may have dependencies or be in use."
    fi
else
    log "Namespace $NAMESPACE_NAME not found, skipping."
fi

# Step 5: Delete CloudWatch Log Groups
log "Step 5: Deleting CloudWatch Log Groups..."
LOG_GROUPS=(
    "$LOG_GROUP_NAME_1"
    "$LOG_GROUP_NAME_2"
    "$LOG_GROUP_NAME_3"
)

# Add DAM log groups if cleanup is enabled
if [ "$CLEANUP_DAM" = true ]; then
    LOG_GROUPS+=(
        "$LOG_GROUP_NAME_4"
        "$LOG_GROUP_NAME_5"
    )
fi

for LOG_GROUP in "${LOG_GROUPS[@]}"; do
    if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query "logGroups[0].logGroupName" --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
        log "Deleting log group $LOG_GROUP..."
        aws logs delete-log-group --log-group-name "$LOG_GROUP"
    else
        log "Log group $LOG_GROUP not found, skipping."
    fi
done

# Step 6: Delete S3 Bucket Content and Bucket
if prompt_for_confirmation "S3 bucket $BUCKET_NAME"; then
    log "Step 6: Emptying and deleting S3 bucket..."
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        log "Emptying bucket $BUCKET_NAME..."
        aws s3 rm "s3://$BUCKET_NAME" --recursive
        
        log "Deleting bucket $BUCKET_NAME..."
        aws s3api delete-bucket --bucket "$BUCKET_NAME"
    else
        log "S3 bucket $BUCKET_NAME not found, skipping."
    fi
fi

# Step 7: Delete Secrets Manager Secret
if prompt_for_confirmation "Secrets Manager secret $SECRET_NAME"; then
    log "Step 7: Deleting Secrets Manager Secret..."
    SECRET_ARN=$(aws secretsmanager list-secrets --query "SecretList[?Name=='$SECRET_NAME'].ARN" --output text)
    
    if [ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ]; then
        log "Deleting secret $SECRET_NAME..."
        aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery
    else
        log "Secret $SECRET_NAME not found, skipping."
    fi
fi

# Step 8: Delete EFS File System
log "Step 8: Deleting EFS File System..."
# Find EFS with tag indicating this setup number
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='setup' && Value=='$SETUP_NUMBER']].FileSystemId" --output text)

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    # Delete all mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --query "MountTargets[].MountTargetId" --output text)
    
    if [ -n "$MOUNT_TARGETS" ]; then
        for MOUNT_TARGET in $MOUNT_TARGETS; do
            log "Deleting mount target $MOUNT_TARGET..."
            aws efs delete-mount-target --mount-target-id "$MOUNT_TARGET"
        done
        
        # Wait for mount targets to be deleted
        log "Waiting for mount targets to be deleted..."
        sleep 30
    fi
    
    # Delete all access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id "$EFS_ID" --query "AccessPoints[].AccessPointId" --output text)
    
    if [ -n "$ACCESS_POINTS" ]; then
        for ACCESS_POINT in $ACCESS_POINTS; do
            log "Deleting access point $ACCESS_POINT..."
            aws efs delete-access-point --access-point-id "$ACCESS_POINT"
        done
    fi
    
    # Delete the file system
    log "Deleting EFS file system $EFS_ID..."
    aws efs delete-file-system --file-system-id "$EFS_ID"
else
    log "No EFS file system found for setup $SETUP_NUMBER, skipping."
fi

# Step 9: Delete Security Group
log "Step 9: Deleting Security Group..."
SG_NAME="${PROJECT_NAME}-ecs-sg-${SETUP_NUMBER}"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query "SecurityGroups[0].GroupId" --output text)

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    log "Deleting security group $SG_NAME ($SG_ID)..."
    
    # First remove all ingress and egress rules
    aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol all --source-group "$SG_ID" 2>/dev/null || true
    aws ec2 revoke-security-group-egress --group-id "$SG_ID" --protocol all --source-group "$SG_ID" 2>/dev/null || true
    
    # Now try to delete the security group (this might take a few attempts)
    attempt=1
    max_attempts=5
    wait_time=15
    
    while [ $attempt -le $max_attempts ]; do
        if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
            log "Security group deleted successfully."
            break
        else
            log "Attempt $attempt of $max_attempts, waiting ${wait_time} seconds..."
            sleep $wait_time
            attempt=$((attempt + 1))
        fi
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log "Warning: Failed to delete security group after $max_attempts attempts. It may still have dependencies."
    fi
else
    log "Security group $SG_NAME not found, skipping."
fi

# Step 10: Remove resources from IAM policies
log "Step 10: Checking if IAM policies need to be updated..."
log "The following IAM policies may have resources related to setup #$SETUP_NUMBER:"
log "- cdx-S3AccessPolicy - Contains S3 bucket ARNs: arn:aws:s3:::$BUCKET_NAME*"
log "- cdx-CloudWatchLogsPolicy - Contains log group ARNs for setup #$SETUP_NUMBER"

if [ "$CLEANUP_DAM" = true ]; then
    log "Note: DAM-specific resources (PostgreSQL, DAM Server) were also removed."
fi

log "Consider manually reviewing and updating these policies if needed."

log ""
log "=== Cleanup Complete ==="
if [ "$CLEANUP_DAM" = true ]; then
    log "All cleanup operations for setup #$SETUP_NUMBER (including DAM) completed."
else
    log "All cleanup operations for setup #$SETUP_NUMBER (ProxySQL only) completed."
fi