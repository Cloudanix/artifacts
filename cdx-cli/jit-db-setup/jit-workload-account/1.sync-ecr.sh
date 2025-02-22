#!/bin/bash

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
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
TARGET_REGION=$(prompt_with_default "Enter the region of jit db setup" "ap-south-1")

REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server" "cloudanix/ecr-aws-jit-query-logging")
IMAGE_TAG="latest"
PLATFORM="linux/amd64"

# Authenticate with the source account's ECR
echo "Authenticating to the source account ECR..."
aws ecr get-login-password --region "$SOURCE_REGION" | docker login --username AWS --password-stdin "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com"

# Authenticate with the target account's ECR
echo "Authenticating to the target account ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | docker login --username AWS --password-stdin "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com"

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
