#!/bin/bash

# Set variables
SOURCE_ACCOUNT_ID="${1:-"774118602354"}"
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "Your AWS Account ID is: $TARGET_ACCOUNT_ID"

SOURCE_REGION="${2:-"us-east-2"}"
TARGET_REGION="${3:-"ap-south-1"}"

REPOSITORIES=("cloudanix/ecr-aws-jit-proxy-sql" "cloudanix/ecr-aws-jit-proxy-server")
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

    # Ensure the repository exists in the target account
    echo "Ensuring repository exists in target account..."
    aws ecr describe-repositories --region "$TARGET_REGION" --repository-names "$REPO" >/dev/null 2>&1 || \
    aws ecr create-repository --region "$TARGET_REGION" --repository-name "$REPO"

    # Push the image to the target account's ECR
    echo "Pushing image to target account..."
    docker push "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"
done

echo "Image transfer complete for all repositories."
