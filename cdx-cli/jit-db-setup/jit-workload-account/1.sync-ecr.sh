#!/bin/bash

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

cleanup_old_images() {
    local repository="$1"
    local region="$2"
    
    # Get all image digests except the latest
    local images_to_delete=$(aws ecr list-images \
        --repository-name "$repository" \
        --region "$region" \
        --query 'imageIds[?imageTag!=`latest`].imageDigest' \
        --output text)
    
    if [ -n "$images_to_delete" ]; then
        echo "Deleting old images..."
        for digest in $images_to_delete; do
            aws ecr batch-delete-image \
                --repository-name "$repository" \
                --region "$region" \
                --image-ids imageDigest=$digest --output text > /dev/null
            echo "Deleted image: $digest"
        done
    else
        echo "No old images to delete"
    fi
}

# Set variables
SOURCE_ACCOUNT_ID="774118602354"
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $TARGET_ACCOUNT_ID"

SOURCE_REGION="us-east-2"
TARGET_REGION_INPUT="${1-"us-east-1"}"
TARGET_REGION=$(prompt_with_default "Enter the region of jit db setup" "$TARGET_REGION_INPUT")

IMAGE_TAG="latest"
PLATFORM="linux/amd64"

# Ask about DAM setup
echo ""
ENABLE_DAM=false
if prompt_yes_no "Enable Database Activity Monitoring (DAM)?" "n"; then
    ENABLE_DAM=true
    echo "DAM will be enabled"
else
    echo "DAM will be disabled"
fi

# Authenticate with the source account's ECR
echo "Authenticating to the source account ECR..."
aws ecr get-login-password --region "$SOURCE_REGION" | docker login --username AWS --password-stdin "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com"

# Authenticate with the target account's ECR
echo "Authenticating to the target account ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | docker login --username AWS --password-stdin "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com"

# Define repositories
REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-query-logging" "cloudanix/ecr-aws-jit-proxy-server")

# Add DAM repositories if enabled
if [ "$ENABLE_DAM" = true ]; then
    REPOSITORIES+=("cloudanix/ecr-aws-jit-dam-server" "cloudanix/ecr-aws-jit-postgresql")
fi

# Loop through repositories
for REPO in "${REPOSITORIES[@]}"; do
    echo "Processing repository: $REPO"

    # Ensure the repository exists in the target account
    echo "Ensuring repository exists in target account..."
    aws ecr describe-repositories --region "$TARGET_REGION" --repository-names "$REPO" >/dev/null 2>&1 || \
    aws ecr create-repository --region "$TARGET_REGION" --repository-name "$REPO"

    # Pull the image from the source account's ECR
    echo "Pulling image from source account..."
    docker pull --platform "$PLATFORM" "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    # Tag the image for the target account's ECR
    echo "Tagging image for target account..."
    docker tag "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG" "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    # Push the image to the target account's ECR
    echo "Pushing image to target account..."
    docker push "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    # Clean up old images
    cleanup_old_images "$REPO" "$TARGET_REGION"
done

echo "Image transfer complete for all repositories."


ECS_SERVICES=("proxysql" "query-logging" "proxyserver")

# Add DAM services if enabled
if [ "$ENABLE_DAM" = true ]; then
    ECS_SERVICES+=("dam-server" "postgresql")
fi

# Loop through ECS Services
for ECS_SERVICE in "${ECS_SERVICES[@]}"; do
    echo "Updating ecs service: $ECS_SERVICE"

    for CLUSTER in "jit-db-cluster" "cdx-jit-db-cluster" "cdx-jit-db-cluster-2" "cdx-jit-db-cluster-3" "cdx-jit-db-cluster-4"; do
        if aws ecs describe-clusters --clusters "$CLUSTER" --region "$TARGET_REGION" --query "clusters[?status=='ACTIVE'] | length(@)" --output text | grep -q "1"; then
            # Check if service exists
            if aws ecs describe-services --cluster "$CLUSTER" --services "$ECS_SERVICE" --region "$TARGET_REGION" --query "services[?status!='INACTIVE'] | length(@)" --output text 2>/dev/null | grep -q "1"; then
                echo "Updating $CLUSTER. service $ECS_SERVICE..."
                aws ecs update-service --cluster "$CLUSTER" --service "$ECS_SERVICE" --force-new-deployment --region "$TARGET_REGION" --output text > /dev/null
            fi
        fi
    done

    sleep 30

done

echo "Services Updated for all ECS Services."
