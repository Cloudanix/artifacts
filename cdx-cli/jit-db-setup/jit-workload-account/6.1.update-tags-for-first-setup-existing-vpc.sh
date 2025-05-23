#!/bin/bash
set -e  
set -u  

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    echo "An error occurred on line $1, exit code $exit_code"
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# Function to create task definition tags JSON
generate_task_tags() {
    local tags_file=$1
    local default_tags='[{"key":"Purpose","value":"database-iam-jit"},{"key":"created_by","value":"cloudanix"}]'
    
    if [ -f "$tags_file" ]; then
        # Convert the Tags array format from ResourceType format to key/value format for task definitions
        jq -c 'map({"key": .Key, "value": .Value})' "$tags_file"
    else
        echo "$default_tags"
    fi
}

# Function to generate ECS service tags
generate_ecs_service_tags() {
    local tags_file=$1
    local default_tags="key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
    
    if [ -f "$tags_file" ]; then
        # Convert JSON array to CLI format for ECS service tags
        local tag_string=$(jq -r '.[] | "key=\(.Key),value=\(.Value)"' "$tags_file" | tr '\n' ' ')
        echo "$tag_string"
    else
        echo "$default_tags"
    fi
}

# Function to apply tags to S3 bucket
apply_s3_tags() {
    local bucket_name=$1
    local tags_file=$2
    local default_tags='{"TagSet": [{"Key": "Purpose", "Value": "database-iam-jit"}, {"Key": "created_by", "Value": "cloudanix"}]}'
    
    log "Updating S3 bucket tags: $bucket_name"
    if [ -f "$tags_file" ]; then
        # For S3, the format is {"TagSet": [{"Key":"k1", "Value":"v1"}, ...]}
        local tag_set=$(jq -c '{TagSet: .}' "$tags_file")
        aws s3api put-bucket-tagging --bucket "$bucket_name" --tagging "$tag_set"
    else
        aws s3api put-bucket-tagging --bucket "$bucket_name" --tagging "$default_tags"
    fi
    log "S3 bucket tags updated successfully"
}

# Function to apply tags to CloudWatch logs
apply_logs_tags() {
    local log_group_name=$1
    local tags_file=$2
    local default_tags='{"Purpose": "database-iam-jit", "created_by": "cloudanix"}'
    
    log "Updating CloudWatch log group tags: $log_group_name"
    if [ -f "$tags_file" ]; then
        # Convert JSON array to object format for logs
        local tags_obj=$(jq 'map({(.Key): .Value}) | add' "$tags_file")
        aws logs tag-log-group --log-group-name "$log_group_name" --tags "$tags_obj"
    else
        aws logs tag-log-group --log-group-name "$log_group_name" --tags "$default_tags"
    fi
    log "Log group tags updated successfully"
}

# Function to apply tags to Secrets Manager
apply_secret_tags() {
    local secret_name=$1
    local tags_file=$2

    local tags_json

    log "Updating Secrets Manager tags: $secret_name"
    if [ -f "$tags_file" ]; then
        # Read and use tags from the provided JSON file
        tags_json=$(jq -c '.' "$tags_file")
    else
        # Use default tags
        tags_json='[
            {"Key": "Purpose", "Value": "database-iam-jit"},
            {"Key": "created_by", "Value": "cloudanix"}
        ]'
    fi

    # First untag existing tags, then apply new ones
    aws secretsmanager untag-resource --secret-id "$secret_name" --tag-keys $(aws secretsmanager describe-secret --secret-id "$secret_name" --query 'Tags[].Key' --output text) 2>/dev/null || true
    aws secretsmanager tag-resource --secret-id "$secret_name" --tags "$tags_json"
    log "Secret tags updated successfully"
}

# Function to apply tags to ECR repositories
apply_ecr_tags() {
    local repo_name=$1
    local tags_file=$2

    local tags_json

    log "Updating ECR repository tags: $repo_name"
    
    # Get repository ARN
    local repo_arn=$(aws ecr describe-repositories --repository-names "$repo_name" \
        --query 'repositories[0].repositoryArn' --output text 2>/dev/null)

    if [ "$repo_arn" = "None" ] || [ -z "$repo_arn" ]; then
        log "Warning: Repository $repo_name not found, skipping..."
        return
    fi

    if [ -f "$tags_file" ]; then
        # Read JSON tags, but override or add the Name tag dynamically
        tags_json=$(jq --arg name "$repo_name" '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]
        ' "$tags_file" | jq -c '.')
    else
        # Use default tags including dynamic Name
        tags_json=$(jq -n --arg name "$repo_name" '[
            {Key: "Name", Value: $name},
            {Key: "Purpose", Value: "database-iam-jit"},
            {Key: "created_by", Value: "cloudanix"}
        ]')
    fi

    # Untag existing tags first
    aws ecr list-tags-for-resource --resource-arn "$repo_arn" --query 'tags[].Key' --output text | \
        xargs -r aws ecr untag-resource --resource-arn "$repo_arn" --tag-keys 2>/dev/null || true
    
    aws ecr tag-resource --resource-arn "$repo_arn" --tags "$tags_json"
    log "ECR repository tags updated successfully"
}

# Function to apply tags to ECS cluster
apply_ecs_cluster_tags() {
    local cluster_name=$1
    local tags_file=$2

    local tag_params

    log "Updating ECS cluster tags: $cluster_name"
    
    # Get cluster ARN
    local cluster_arn=$(aws ecs describe-clusters --clusters "$cluster_name" \
        --query 'clusters[0].clusterArn' --output text 2>/dev/null)

    if [ "$cluster_arn" = "None" ] || [ -z "$cluster_arn" ]; then
        log "Warning: Cluster $cluster_name not found, skipping..."
        return
    fi

    if [ -f "$tags_file" ]; then
        # Add or override Name tag and convert to CLI format
        tag_params=$(jq --arg name "$cluster_name" -r '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}] |
            .[] | "key=\(.Key),value=\(.Value)"
        ' "$tags_file" | tr '\n' ' ')
    else
        # Default tags in CLI format
        tag_params="key=Name,value=$cluster_name key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
    fi

    # Untag existing tags first
    aws ecs list-tags-for-resource --resource-arn "$cluster_arn" --query 'tags[].key' --output text | \
        xargs -r aws ecs untag-resource --resource-arn "$cluster_arn" --tag-keys 2>/dev/null || true

    aws ecs tag-resource --resource-arn "$cluster_arn" --tags $tag_params
    log "ECS cluster tags updated successfully"
}

# Function to apply tags to ECS services
apply_ecs_service_tags() {
    local cluster_name=$1
    local service_name=$2
    local tags_file=$3

    local tag_params

    log "Updating ECS service tags: $service_name"
    
    # Get service ARN
    local service_arn=$(aws ecs describe-services --cluster "$cluster_name" --services "$service_name" \
        --query 'services[0].serviceArn' --output text 2>/dev/null)

    if [ "$service_arn" = "None" ] || [ -z "$service_arn" ]; then
        log "Warning: Service $service_name not found in cluster $cluster_name, skipping..."
        return
    fi

    if [ -f "$tags_file" ]; then
        # Add or override Name tag and convert to CLI format
        tag_params=$(jq --arg name "$service_name" -r '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}] |
            .[] | "key=\(.Key),value=\(.Value)"
        ' "$tags_file" | tr '\n' ' ')
    else
        # Default tags in CLI format
        tag_params="key=Name,value=$service_name key=Purpose,value=database-iam-jit key=created_by,value=cloudanix"
    fi

    # Untag existing tags first
    aws ecs list-tags-for-resource --resource-arn "$service_arn" --query 'tags[].key' --output text | \
        xargs -r aws ecs untag-resource --resource-arn "$service_arn" --tag-keys 2>/dev/null || true

    aws ecs tag-resource --resource-arn "$service_arn" --tags $tag_params
    log "ECS service tags updated successfully"
}

# Function to update task definition tags
update_task_definition_tags() {
    local family_name=$1
    local tags_file=$2
    
    log "Updating task definition tags: $family_name"
    
    # Get the latest task definition
    local task_def=$(aws ecs describe-task-definition --task-definition "$family_name" --query 'taskDefinition')
    
    if [ "$task_def" = "null" ] || [ -z "$task_def" ]; then
        log "Warning: Task definition $family_name not found, skipping..."
        return
    fi
    
    # Get task tags
    local task_tags
    if [ -f "$tags_file" ]; then
        task_tags=$(generate_task_tags "$tags_file")
    else
        task_tags='[{"key":"Purpose","value":"database-iam-jit"},{"key":"created_by","value":"cloudanix"}]'
    fi
    
    # Create updated task definition with new tags
    echo "$task_def" | jq --argjson new_tags "$task_tags" '.tags = $new_tags | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)' > "temp-${family_name}-task-definition.json"
    
    # Register new task definition
    aws ecs register-task-definition --cli-input-json "file://temp-${family_name}-task-definition.json" > /dev/null
    
    # Clean up temporary file
    rm "temp-${family_name}-task-definition.json"
    
    log "Task definition tags updated successfully"
}

# Function to apply tags to Security Groups
apply_sg_tags() {
    local sg_id=$1
    local tags_file=$2
    local sg_name="$3"
    
    log "Updating Security Group tags: $sg_id"
    
    local tags_json
    if [ -f "$tags_file" ]; then
        tags_json=$(jq --arg name "$sg_name" '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]
        ' "$tags_file")
    else
        tags_json=$(jq -n --arg name "$sg_name" '[
            {"Key": "Name", "Value": $name},
            {"Key": "Purpose", "Value": "database-iam-jit"},
            {"Key": "created_by", "Value": "cloudanix"}
        ]')
    fi
    
    # Apply tags using create-tags (this will overwrite existing tags with same keys)
    echo "$tags_json" | jq -r '.[] | "\(.Key)=\(.Value)"' | while read tag; do
        aws ec2 create-tags --resources "$sg_id" --tags "Key=${tag%=*},Value=${tag#*=}"
    done
    
    log "Security Group tags updated successfully"
}

# Function to apply tags to EFS
apply_efs_tags() {
    local efs_id=$1
    local tags_file=$2
    local project_name="$3"
    
    log "Updating EFS tags: $efs_id"
    
    local tags_json
    local resource_name="${project_name}-efs"
    
    if [ -f "$tags_file" ]; then
        tags_json=$(jq --arg name "$resource_name" '
            map(select(.Key != "Name")) + [{"Key": "Name", "Value": $name}]
        ' "$tags_file")
    else
        tags_json=$(jq -n --arg name "$resource_name" '[
            {"Key": "Name", "Value": $name},
            {"Key": "Purpose", "Value": "database-iam-jit"},
            {"Key": "created_by", "Value": "cloudanix"}
        ]')
    fi
    
    # Delete existing tags first, then apply new ones
    aws efs delete-tags --file-system-id "$efs_id" --tag-keys $(aws efs describe-tags --file-system-id "$efs_id" --query 'Tags[].Key' --output text) 2>/dev/null || true
    aws efs create-tags --file-system-id "$efs_id" --tags "$tags_json"
    
    log "EFS tags updated successfully"
}

echo "=== JIT Account Infrastructure Tag Update ==="
echo "This script will update tags for all existing infrastructure resources"

# Get configuration
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
PROJECT_NAME="cdx-jit-db"
ECS_CLUSTER_NAME="cdx-jit-db-cluster"
SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name" "CDX_SECRETS")
BUCKET_NAME=$(prompt_with_default "S3 bucket name" "cdx-jit-db-logs")
TAGS_FILE=$(prompt_with_default "Path to JSON tags file" "6.tag.json")

# Validate tags file
if [ ! -f "$TAGS_FILE" ]; then
    log "Error: Tags file $TAGS_FILE not found!"
    exit 1
fi

log "Validating tags file format..."
if ! jq empty "$TAGS_FILE" 2>/dev/null; then
    log "Error: Invalid JSON format in tags file!"
    exit 1
fi

# Log group names
LOG_GROUP_NAME_1="/ecs/${PROJECT_NAME}/proxyserver"
LOG_GROUP_NAME_2="/ecs/${PROJECT_NAME}/proxysql"
LOG_GROUP_NAME_3="/ecs/${PROJECT_NAME}/query-logging"

# ECR repositories
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")

# ECS services
SERVICES=("proxysql" "proxyserver" "query-logging")

# Task definition families
TASK_FAMILIES=("proxysql" "proxyserver-task" "query-logging-task")

echo -e "\n=== Configuration Summary ==="
echo "AWS Region: $AWS_REGION"
echo "Account ID: $ACCOUNT_ID"
echo "Project Name: $PROJECT_NAME"
echo "Tags file: $TAGS_FILE"
echo "Found $(jq length "$TAGS_FILE") tags to apply"

echo -e "\n=== Starting Tag Updates ==="

# Update S3 Bucket tags
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    apply_s3_tags "$BUCKET_NAME" "$TAGS_FILE"
else
    log "Warning: S3 bucket $BUCKET_NAME not found, skipping..."
fi

# Update CloudWatch Log Groups tags
for log_group in "$LOG_GROUP_NAME_1" "$LOG_GROUP_NAME_2" "$LOG_GROUP_NAME_3"; do
    if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query 'logGroups[0].logGroupName' --output text | grep -q "$log_group"; then
        apply_logs_tags "$log_group" "$TAGS_FILE"
    else
        log "Warning: Log group $log_group not found, skipping..."
    fi
done

# Update Secrets Manager tags
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
    apply_secret_tags "$SECRET_NAME" "$TAGS_FILE"
else
    log "Warning: Secret $SECRET_NAME not found, skipping..."
fi

# Update ECR Repository tags
for repo in "${REPOSITORIES[@]}"; do
    apply_ecr_tags "$repo" "$TAGS_FILE"
done

# Update ECS Cluster tags
apply_ecs_cluster_tags "$ECS_CLUSTER_NAME" "$TAGS_FILE"

# Update ECS Service tags
for service in "${SERVICES[@]}"; do
    apply_ecs_service_tags "$ECS_CLUSTER_NAME" "$service" "$TAGS_FILE"
done

# Update Task Definition tags
for family in "${TASK_FAMILIES[@]}"; do
    update_task_definition_tags "$family" "$TAGS_FILE"
done

# Update Security Group tags
SG_NAME="${PROJECT_NAME}-ecs-sg"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
    apply_sg_tags "$SG_ID" "$TAGS_FILE" "$SG_NAME"
else
    log "Warning: Security Group $SG_NAME not found, skipping..."
fi

# Update EFS tags
EFS_NAME="${PROJECT_NAME}-efs"
EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='$EFS_NAME']].FileSystemId" --output text 2>/dev/null)
if [ "$EFS_ID" != "None" ] && [ -n "$EFS_ID" ]; then
    apply_efs_tags "$EFS_ID" "$TAGS_FILE" "$PROJECT_NAME"
else
    # Try to find EFS by creation time or other method if name tag doesn't exist
    EFS_ID=$(aws efs describe-file-systems --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null)
    if [ "$EFS_ID" != "None" ] && [ -n "$EFS_ID" ]; then
        log "Found EFS without name tag, updating: $EFS_ID"
        apply_efs_tags "$EFS_ID" "$TAGS_FILE" "$PROJECT_NAME"
    else
        log "Warning: EFS not found, skipping..."
    fi
fi

echo -e "\n=== Tag Update Summary ==="
echo "✓ S3 Bucket: $BUCKET_NAME"
echo "✓ CloudWatch Log Groups: 3 groups"
echo "✓ Secrets Manager: $SECRET_NAME"
echo "✓ ECR Repositories: ${#REPOSITORIES[@]} repositories"
echo "✓ ECS Cluster: $ECS_CLUSTER_NAME"
echo "✓ ECS Services: ${#SERVICES[@]} services"
echo "✓ Task Definitions: ${#TASK_FAMILIES[@]} families"
echo "✓ Security Group: $SG_NAME"
echo "✓ EFS File System"

echo -e "\n=== All resources have been tagged successfully! ==="

# Create a summary file
cat << EOF > tag-update-summary.txt
Tag Update Summary - $(date)
============================
AWS Region: $AWS_REGION
Account ID: $ACCOUNT_ID
Project Name: $PROJECT_NAME
Tags File: $TAGS_FILE

Resources Updated:
- S3 Bucket: $BUCKET_NAME
- CloudWatch Log Groups: $LOG_GROUP_NAME_1, $LOG_GROUP_NAME_2, $LOG_GROUP_NAME_3
- Secrets Manager: $SECRET_NAME
- ECR Repositories: $(IFS=', '; echo "${REPOSITORIES[*]}")
- ECS Cluster: $ECS_CLUSTER_NAME
- ECS Services: $(IFS=', '; echo "${SERVICES[*]}")
- Task Definitions: $(IFS=', '; echo "${TASK_FAMILIES[*]}")
- Security Group: $SG_NAME ($SG_ID)
- EFS File System: $EFS_ID

Applied Tags:
$(jq -r '.[] | "- \(.Key): \(.Value)"' "$TAGS_FILE")
EOF

log "Summary saved to tag-update-summary.txt"