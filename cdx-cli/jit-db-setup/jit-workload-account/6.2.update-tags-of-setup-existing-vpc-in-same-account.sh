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
    local existing_tags=$(aws secretsmanager describe-secret --secret-id "$secret_name" --query 'Tags[].Key' --output text 2>/dev/null || echo "")
    if [ -n "$existing_tags" ]; then
        aws secretsmanager untag-resource --secret-id "$secret_name" --tag-keys $existing_tags 2>/dev/null || true
    fi
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
        --query 'repositories[0].repositoryArn' --output text 2>/dev/null || echo "None")

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
    local existing_tag_keys=$(aws ecr list-tags-for-resource --resource-arn "$repo_arn" --query 'tags[].Key' --output text 2>/dev/null || echo "")
    if [ -n "$existing_tag_keys" ]; then
        aws ecr untag-resource --resource-arn "$repo_arn" --tag-keys $existing_tag_keys 2>/dev/null || true
    fi
    
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
        --query 'clusters[0].clusterArn' --output text 2>/dev/null || echo "None")

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
    local existing_tag_keys=$(aws ecs list-tags-for-resource --resource-arn "$cluster_arn" --query 'tags[].key' --output text 2>/dev/null || echo "")
    if [ -n "$existing_tag_keys" ]; then
        aws ecs untag-resource --resource-arn "$cluster_arn" --tag-keys $existing_tag_keys 2>/dev/null || true
    fi

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
        --query 'services[0].serviceArn' --output text 2>/dev/null || echo "None")

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
    local existing_tag_keys=$(aws ecs list-tags-for-resource --resource-arn "$service_arn" --query 'tags[].key' --output text 2>/dev/null || echo "")
    if [ -n "$existing_tag_keys" ]; then
        aws ecs untag-resource --resource-arn "$service_arn" --tag-keys $existing_tag_keys 2>/dev/null || true
    fi

    aws ecs tag-resource --resource-arn "$service_arn" --tags $tag_params
    log "ECS service tags updated successfully"
}

# Function to update task definition tags
update_task_definition_tags() {
    local family_name=$1
    local tags_file=$2
    
    log "Updating task definition tags: $family_name"
    
    # Get the latest task definition
    local task_def=$(aws ecs describe-task-definition --task-definition "$family_name" --query 'taskDefinition' 2>/dev/null || echo "null")
    
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
    local setup_number="$4"
    
    log "Updating EFS tags: $efs_id"
    
    local tags_json
    local resource_name="${project_name}-efs-${setup_number}"
    
    if [ -f "$tags_file" ]; then
        tags_json=$(jq --arg name "$resource_name" --arg setup "$setup_number" '
            map(select(.Key != "Name" and .Key != "setup")) + [{"Key": "Name", "Value": $name}, {"Key": "setup", "Value": $setup}]
        ' "$tags_file")
    else
        tags_json=$(jq -n --arg name "$resource_name" --arg setup "$setup_number" '[
            {"Key": "Name", "Value": $name},
            {"Key": "setup", "Value": $setup},
            {"Key": "Purpose", "Value": "database-iam-jit"},
            {"Key": "created_by", "Value": "cloudanix"}
        ]')
    fi
    
    # Delete existing tags first, then apply new ones
    local existing_tag_keys=$(aws efs describe-tags --file-system-id "$efs_id" --query 'Tags[].Key' --output text 2>/dev/null || echo "")
    if [ -n "$existing_tag_keys" ]; then
        aws efs delete-tags --file-system-id "$efs_id" --tag-keys $existing_tag_keys 2>/dev/null || true
    fi
    aws efs create-tags --file-system-id "$efs_id" --tags "$tags_json"
    
    log "EFS tags updated successfully"
}

# Function to process a specific setup
process_setup() {
    local setup_number=$1
    local tags_file=$2
    local project_name="cdx-jit-db"
    
    log "Processing setup #${setup_number}..."
    
    # Define resource names for this setup
    local cluster_name="${project_name}-cluster-${setup_number}"
    local sg_name="${project_name}-ecs-sg-${setup_number}"
    
    # Log group names for this setup
    local log_groups=(
        "/ecs/${project_name}/proxyserver-${setup_number}"
        "/ecs/${project_name}/proxysql-${setup_number}"
        "/ecs/${project_name}/query-logging-${setup_number}"
    )
    
    # ECS services
    local services=("proxysql" "proxyserver" "query-logging")
    
    # Task definition families for this setup
    local task_families=(
        "proxysql-${setup_number}"
        "proxyserver-task-${setup_number}"
        "query-logging-task-${setup_number}"
    )
    
    # Update CloudWatch Log Groups tags
    for log_group in "${log_groups[@]}"; do
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$log_group"; then
            apply_logs_tags "$log_group" "$tags_file"
        else
            log "Warning: Log group $log_group not found, skipping..."
        fi
    done

    # Update ECS Cluster tags
    apply_ecs_cluster_tags "$cluster_name" "$tags_file"

    # Update ECS Service tags
    for service in "${services[@]}"; do
        apply_ecs_service_tags "$cluster_name" "$service" "$tags_file"
    done

    # Update Task Definition tags
    for family in "${task_families[@]}"; do
        update_task_definition_tags "$family" "$tags_file"
    done

    # Update Security Group tags
    local sg_id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg_name" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    if [ "$sg_id" != "None" ] && [ -n "$sg_id" ]; then
        apply_sg_tags "$sg_id" "$tags_file" "$sg_name"
    else
        log "Warning: Security Group $sg_name not found, skipping..."
    fi

    # Update EFS tags - Find EFS with setup-specific tag or name pattern
    local efs_id=""
    
    # First try to find by Name tag pattern
    efs_id=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${setup_number}')]].FileSystemId" --output text 2>/dev/null || echo "")
    
    # If not found by name, try to find by setup tag
    if [ -z "$efs_id" ] || [ "$efs_id" = "None" ]; then
        efs_id=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='setup' && Value=='${setup_number}']].FileSystemId" --output text 2>/dev/null || echo "")
    fi
    
    # If still not found and this is setup 2 or higher, try to find untagged EFS systems and tag them
    if [ -z "$efs_id" ] || [ "$efs_id" = "None" ]; then
        if [ "$setup_number" -gt 1 ]; then
            # Get all EFS systems and find ones without setup tags
            local all_efs=$(aws efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text 2>/dev/null || echo "")
            for efs in $all_efs; do
                local has_setup_tag=$(aws efs describe-tags --file-system-id "$efs" --query "Tags[?Key=='setup'].Value" --output text 2>/dev/null || echo "")
                if [ -z "$has_setup_tag" ]; then
                    log "Found EFS without setup tag, assuming it belongs to setup #${setup_number}: $efs"
                    efs_id="$efs"
                    break
                fi
            done
        fi
    fi
    
    if [ -n "$efs_id" ] && [ "$efs_id" != "None" ]; then
        apply_efs_tags "$efs_id" "$tags_file" "$project_name" "$setup_number"
    else
        log "Warning: EFS for setup #${setup_number} not found, skipping..."
    fi
    
    log "Setup #${setup_number} processing completed"
}

echo "=== JIT Account Infrastructure Tag Update - Multi-Setup Support ==="
echo "This script will update tags for infrastructure resources across multiple setups"

# Get configuration
AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
PROJECT_NAME="cdx-jit-db"

# Get setup numbers to process
SETUP_NUMBERS=$(prompt_with_default "Enter setup numbers to process" "2")
read -a SETUP_ARRAY <<< "$SETUP_NUMBERS"

# Secret and S3 bucket configuration
SECRET_NAME=$(prompt_with_default "Secrets Manager Secret Name (leave empty to skip)" "")
BUCKET_PREFIX=$(prompt_with_default "S3 bucket name prefix (e.g., 'cdx-jit-db-logs')" "cdx-jit-db-logs")

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

# ECR repositories (these are shared across setups)
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")

echo -e "\n=== Configuration Summary ==="
echo "AWS Region: $AWS_REGION"
echo "Account ID: $ACCOUNT_ID"
echo "Project Name: $PROJECT_NAME"
echo "Setup Numbers: ${SETUP_NUMBERS}"
echo "Tags file: $TAGS_FILE"
echo "Found $(jq length "$TAGS_FILE") tags to apply"

if [ -n "$SECRET_NAME" ]; then
    echo "Secret Name: $SECRET_NAME"
fi

echo -e "\n=== Starting Tag Updates ==="

# Update shared resources (ECR repositories and optionally secrets)
log "Updating shared resources..."

# Update ECR Repository tags (shared across all setups)
for repo in "${REPOSITORIES[@]}"; do
    apply_ecr_tags "$repo" "$TAGS_FILE"
done

# Update Secrets Manager tags (if specified)
if [ -n "$SECRET_NAME" ]; then
    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
        apply_secret_tags "$SECRET_NAME" "$TAGS_FILE"
    else
        log "Warning: Secret $SECRET_NAME not found, skipping..."
    fi
fi

# Process each setup
for setup_num in "${SETUP_ARRAY[@]}"; do
    log "=== Processing Setup #${setup_num} ==="
    
    # Handle S3 bucket naming for different setups
    if [ "$setup_num" = "1" ]; then
        # First setup might not have suffix
        bucket_name="$BUCKET_PREFIX"
        # Also try with suffix in case it was created with one
        alt_bucket_name="${BUCKET_PREFIX}-${setup_num}"
    else
        # Other setups likely have suffix
        bucket_name="${BUCKET_PREFIX}-${setup_num}"
        alt_bucket_name="$BUCKET_PREFIX"
    fi
    
    # Try to find and update S3 bucket
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        apply_s3_tags "$bucket_name" "$TAGS_FILE"
    elif aws s3api head-bucket --bucket "$alt_bucket_name" 2>/dev/null; then
        apply_s3_tags "$alt_bucket_name" "$TAGS_FILE"
        bucket_name="$alt_bucket_name"
    else
        log "Warning: S3 bucket for setup #${setup_num} not found (tried: $bucket_name, $alt_bucket_name), skipping..."
    fi
    
    # Process setup-specific resources
    process_setup "$setup_num" "$TAGS_FILE"
done

echo -e "\n=== Tag Update Summary ==="
echo "✓ Shared ECR Repositories: ${#REPOSITORIES[@]} repositories"
if [ -n "$SECRET_NAME" ]; then
    echo "✓ Secrets Manager: $SECRET_NAME"
fi

for setup_num in "${SETUP_ARRAY[@]}"; do
    echo "✓ Setup #${setup_num}:"
    echo "  - S3 Bucket: ${BUCKET_PREFIX}(-${setup_num})"
    echo "  - CloudWatch Log Groups: 3 groups"
    echo "  - ECS Cluster: cdx-jit-db-cluster-${setup_num}"
    echo "  - ECS Services: 3 services"
    echo "  - Task Definitions: 3 families"
    echo "  - Security Group: cdx-jit-db-ecs-sg-${setup_num}"
    echo "  - EFS File System"
done

echo -e "\n=== All resources have been tagged successfully! ==="

# Create a summary file
cat << EOF > tag-update-summary-$(date +%Y%m%d-%H%M%S).txt
Tag Update Summary - $(date)
============================
AWS Region: $AWS_REGION
Account ID: $ACCOUNT_ID
Project Name: $PROJECT_NAME
Setup Numbers: ${SETUP_NUMBERS}
Tags File: $TAGS_FILE

Shared Resources Updated:
- ECR Repositories: $(IFS=', '; echo "${REPOSITORIES[*]}")
$([ -n "$SECRET_NAME" ] && echo "- Secrets Manager: $SECRET_NAME")

Setup-Specific Resources Updated:
$(for setup_num in "${SETUP_ARRAY[@]}"; do
    echo "Setup #${setup_num}:"
    echo "  - S3 Bucket: ${BUCKET_PREFIX}(-${setup_num})"
    echo "  - CloudWatch Log Groups: /ecs/cdx-jit-db/proxyserver-${setup_num}, /ecs/cdx-jit-db/proxysql-${setup_num}, /ecs/cdx-jit-db/query-logging-${setup_num}"
    echo "  - ECS Cluster: cdx-jit-db-cluster-${setup_num}"
    echo "  - ECS Services: proxysql, proxyserver, query-logging"
    echo "  - Task Definitions: proxysql-${setup_num}, proxyserver-task-${setup_num}, query-logging-task-${setup_num}"
    echo "  - Security Group: cdx-jit-db-ecs-sg-${setup_num}"
    echo "  - EFS File System"
    echo ""
done)

Applied Tags:
$(jq -r '.[] | "- \(.Key): \(.Value)"' "$TAGS_FILE")
EOF

log "Summary saved to tag-update-summary-$(date +%Y%m%d-%H%M%S).txt"