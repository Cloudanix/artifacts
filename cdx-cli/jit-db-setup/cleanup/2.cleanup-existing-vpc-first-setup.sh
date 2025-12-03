#!/bin/bash
set -e  # Exit on error
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Function to check if resource exists and delete it if it does
resource_delete() {
    local resource_type=$1
    local identifier=$2
    local cmd=$3
    
    log "Checking for ${resource_type}: ${identifier}"
    if eval "$cmd"; then
        log "Deleting ${resource_type}: ${identifier}"
        eval "$4"
        log "${resource_type} deleted: ${identifier}"
    else
        log "${resource_type} not found: ${identifier} - skipping"
    fi
}

# Function to prompt yes/no
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

# Get configuration
log "=== JIT Account Infrastructure Cleanup ==="
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
AWS_REGION=$(read -p "AWS Region [$AWS_REGION]: " input; echo "${input:-$AWS_REGION}")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
log "Your AWS Account ID is: $ACCOUNT_ID"

# Ask about DAM cleanup
echo ""
CLEANUP_DAM=false
if prompt_yes_no "Was DAM (Database Activity Monitoring) enabled in this setup?" "n"; then
    CLEANUP_DAM=true
    echo "DAM resources will be included in cleanup"
else
    echo "Only ProxySQL resources will be cleaned up"
fi

# Project Configuration
PROJECT_NAME="cdx-jit-db"
ECS_CLUSTER_NAME="cdx-jit-db-cluster"
SECRET_NAME=$(read -p "Secrets Manager Secret Name [CDX_SECRETS]: " input; echo "${input:-CDX_SECRETS}")
BUCKET_NAME=$(read -p "S3 bucket name [cdx-jit-db-logs]: " input; echo "${input:-cdx-jit-db-logs}")

# Log configuration
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"
LOG_GROUP_NAME_3="/ecs/${PROJECT_NAME}/query-logging"

# DAM-specific log groups
if [ "$CLEANUP_DAM" = true ]; then
    LOG_GROUP_NAME_4="/ecs/${PROJECT_NAME}/dam-server"
    LOG_GROUP_NAME_5="/ecs/${PROJECT_NAME}/postgresql"
fi

log "=== Configuration Summary ==="
log "AWS Region: $AWS_REGION"
log "Project Name: $PROJECT_NAME"
log "ECS Cluster Name: $ECS_CLUSTER_NAME"
log "Secrets Name: $SECRET_NAME"
log "S3 Bucket Name: $BUCKET_NAME"
log "Cleanup DAM: $CLEANUP_DAM"

# Step 1: Delete ECS Services
log "Checking for ECS services..."
SERVICE_NAMES=("proxysql" "proxyserver" "query-logging")

# Add DAM services if cleanup is enabled
if [ "$CLEANUP_DAM" = true ]; then
    SERVICE_NAMES+=("dam-server" "postgresql")
fi

for service_name in "${SERVICE_NAMES[@]}"; do
    # Check if service exists
    if aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $service_name --region $AWS_REGION --query "services[?status=='ACTIVE']" --output text | grep -q $service_name; then
        log "Updating service to 0 desired count: $service_name"
        aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $service_name --desired-count 0 --region $AWS_REGION --no-cli-pager || log "Failed to update service to 0: $service_name"
        
        log "Waiting for service to scale down: $service_name"
        aws ecs wait services-stable --cluster $ECS_CLUSTER_NAME --services $service_name --region $AWS_REGION || log "Service didn't scale down properly: $service_name"
        
        log "Deleting service: $service_name"
        aws ecs delete-service --cluster $ECS_CLUSTER_NAME --service $service_name --force --region $AWS_REGION --no-cli-pager || log "Failed to delete service: $service_name"
    else
        log "Service not found: $service_name - skipping"
    fi
done

# Step 2: Delete Task Definitions
log "Checking for task definitions..."
TASK_FAMILIES=("proxyserver-task" "proxysql" "query-logging-task")

# Add DAM task families if cleanup is enabled
if [ "$CLEANUP_DAM" = true ]; then
    TASK_FAMILIES+=("dam-server-task" "postgresql-task")
fi

for family in "${TASK_FAMILIES[@]}"; do
    # List all active revisions
    revisions=$(aws ecs list-task-definitions --family-prefix $family --status ACTIVE --region $AWS_REGION --query 'taskDefinitionArns[*]' --output text)
    
    if [ -n "$revisions" ]; then
        log "Found task definitions for family: $family"
        
        for revision in $revisions; do
            log "Deregistering task definition: $revision"
            aws ecs deregister-task-definition --task-definition $revision --region $AWS_REGION --no-cli-pager || log "Failed to deregister task definition: $revision"
        done
    else
        log "No task definitions found for family: $family - skipping"
    fi
done

# Step 3: Delete ECS Cluster
resource_delete "ECS cluster" "$ECS_CLUSTER_NAME" \
    "aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --region $AWS_REGION --query 'clusters[0].status' --output text | grep -q ACTIVE" \
    "aws ecs delete-cluster --cluster $ECS_CLUSTER_NAME --region $AWS_REGION --no-cli-pager"

# Step 4: Delete Service Discovery Namespace
log "Checking for Service Discovery namespace..."
NAMESPACE_ID=$(aws servicediscovery list-namespaces --region $AWS_REGION --query "Namespaces[?Name=='proxysql-proxyserver'].Id" --output text)

if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    # Need to list and delete all services in the namespace first
    services=$(aws servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=$NAMESPACE_ID" --region $AWS_REGION --query 'Services[*].Id' --output text)
    
    for service_id in $services; do
        log "Deleting service discovery service: $service_id"
        aws servicediscovery delete-service --id $service_id --region $AWS_REGION --no-cli-pager || log "Failed to delete service discovery service: $service_id"
    done
    
    # Now delete the namespace
    log "Deleting service discovery namespace: $NAMESPACE_ID"
    aws servicediscovery delete-namespace --id $NAMESPACE_ID --region $AWS_REGION --no-cli-pager || log "Failed to delete namespace: $NAMESPACE_ID"
else
    log "Service Discovery namespace not found - skipping"
fi

# Step 5: Delete EFS Resources
log "Checking for EFS resources..."
EFS_ID=$(aws efs describe-file-systems --region $AWS_REGION --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId" --output text)

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    # Delete access points
    access_points=$(aws efs describe-access-points --file-system-id $EFS_ID --region $AWS_REGION --query 'AccessPoints[*].AccessPointId' --output text)
    
    for ap_id in $access_points; do
        log "Deleting EFS access point: $ap_id"
        aws efs delete-access-point --access-point-id $ap_id --region $AWS_REGION --no-cli-pager || log "Failed to delete access point: $ap_id"
    done
    
    # Delete mount targets
    mount_targets=$(aws efs describe-mount-targets --file-system-id $EFS_ID --region $AWS_REGION --query 'MountTargets[*].MountTargetId' --output text)
    
    for mt_id in $mount_targets; do
        log "Deleting EFS mount target: $mt_id"
        aws efs delete-mount-target --mount-target-id $mt_id --region $AWS_REGION --no-cli-pager || log "Failed to delete mount target: $mt_id"
    done
    
    # Wait for mount targets to be deleted
    log "Waiting for mount targets to be deleted..."
    sleep 30
    
    # Delete file system
    log "Deleting EFS file system: $EFS_ID"
    aws efs delete-file-system --file-system-id $EFS_ID --region $AWS_REGION --no-cli-pager || log "Failed to delete EFS: $EFS_ID"
else
    log "EFS file system not found - skipping"
fi

# Step 6: Delete Security Group
log "Checking for security group..."
SG_ID=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" --query 'SecurityGroups[*].GroupId' --output text)

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    log "Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id $SG_ID --region $AWS_REGION --no-cli-pager || log "Failed to delete security group: $SG_ID"
else
    log "Security group not found - skipping"
fi

# Step 7: Delete CloudWatch Log Groups
LOG_GROUPS=("$LOG_GROUP_NAME_1" "$LOG_GROUP_NAME_2" "$LOG_GROUP_NAME_3")

# Add DAM log groups if cleanup is enabled
if [ "$CLEANUP_DAM" = true ]; then
    LOG_GROUPS+=("$LOG_GROUP_NAME_4" "$LOG_GROUP_NAME_5")
fi

for lg in "${LOG_GROUPS[@]}"; do
    resource_delete "CloudWatch log group" "$lg" \
        "aws logs describe-log-groups --log-group-name-prefix $lg --region $AWS_REGION --query 'logGroups[0].logGroupName' --output text | grep -q $lg" \
        "aws logs delete-log-group --log-group-name $lg --region $AWS_REGION --no-cli-pager"
done

# Step 8: Delete Secrets Manager Secret
resource_delete "Secrets Manager secret" "$SECRET_NAME" \
    "aws secretsmanager describe-secret --secret-id $SECRET_NAME --region $AWS_REGION --query 'ARN' --output text | grep -q $SECRET_NAME" \
    "aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery --region $AWS_REGION --no-cli-pager"

# Step 9: Delete S3 Bucket
log "Checking for S3 bucket: $BUCKET_NAME"
if aws s3api head-bucket --bucket $BUCKET_NAME --region $AWS_REGION 2>/dev/null; then
    log "Emptying S3 bucket: $BUCKET_NAME"
    aws s3 rm s3://$BUCKET_NAME --recursive --region $AWS_REGION || log "Failed to empty bucket: $BUCKET_NAME"
    
    log "Deleting S3 bucket: $BUCKET_NAME"
    aws s3api delete-bucket --bucket $BUCKET_NAME --region $AWS_REGION --no-cli-pager || log "Failed to delete bucket: $BUCKET_NAME"
else
    log "S3 bucket not found: $BUCKET_NAME - skipping"
fi

# Step 10: Delete IAM Policies and Roles
log "Cleaning up IAM resources..."

# Detach and delete policies
POLICIES=("cdx-ECSSecretsAccessPolicy" "cdx-ECSRDSAssumeRolePolicy" "cdx-EFSAccessPolicy" "cdx-CloudWatchLogsPolicy" "cdx-S3AccessPolicy")
for policy_name in "${POLICIES[@]}"; do
    policy_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$policy_name'].Arn" --output text)
    
    if [ -n "$policy_arn" ] && [ "$policy_arn" != "None" ]; then
        # Check if policy is attached to any roles
        attached_roles=$(aws iam list-entities-for-policy --policy-arn $policy_arn --entity-filter Role --query 'PolicyRoles[*].RoleName' --output text)
        
        for role_name in $attached_roles; do
            log "Detaching policy $policy_name from role $role_name"
            aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn || log "Failed to detach policy $policy_name from role $role_name"
        done
        
        log "Deleting IAM policy: $policy_name"
        aws iam delete-policy --policy-arn $policy_arn || log "Failed to delete policy: $policy_name"
    else
        log "IAM policy not found: $policy_name - skipping"
    fi
done

# Delete role
role_name="cdx-ECSTaskRole"
if aws iam get-role --role-name $role_name >/dev/null 2>&1; then
    # Detach managed policies
    attached_policies=$(aws iam list-attached-role-policies --role-name $role_name --query 'AttachedPolicies[*].PolicyArn' --output text)
    
    for policy_arn in $attached_policies; do
        log "Detaching policy $policy_arn from role $role_name"
        aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn || log "Failed to detach policy $policy_arn from role $role_name"
    done
    
    log "Deleting IAM role: $role_name"
    aws iam delete-role --role-name $role_name || log "Failed to delete role: $role_name"
else
    log "IAM role not found: $role_name - skipping"
fi

# Step 11: Delete ECR Repositories
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")

# Add DAM repositories if cleanup is enabled
if [ "$CLEANUP_DAM" = true ]; then
    REPOSITORIES+=("cloudanix/ecr-aws-jit-dam-server" "cloudanix/ecr-aws-jit-postgresql")
fi

for repo in "${REPOSITORIES[@]}"; do
    if aws ecr describe-repositories --repository-names "$repo" --region $AWS_REGION >/dev/null 2>&1; then
        log "Deleting ECR repository: $repo"
        # Force delete the repository and all images within it
        aws ecr delete-repository --repository-name "$repo" --force --region $AWS_REGION || log "Failed to delete ECR repository: $repo"
    else
        log "ECR repository not found: $repo - skipping"
    fi
done

log "=== Cleanup Complete ==="
log "All JIT infrastructure resources have been cleaned up."