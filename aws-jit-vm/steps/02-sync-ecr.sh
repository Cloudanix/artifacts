#!/usr/bin/env bash
# =============================================================================
# Step: Sync ECR Images (VM)
# =============================================================================
# Pulls VM container images (sshpiper, proxyserver, logging) from the
# Cloudanix source ECR and pushes them to the customer's target ECR.
# Creates ECR repositories if they don't exist.
#
# Required env vars:
#   AWS_REGION
#
# Outputs:
#   OUTPUT:ECR_SYNCED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION

# =============================================================================
# CONFIGURATION
# =============================================================================

SOURCE_ACCOUNT_ID="774118602354"
SOURCE_REGION="us-east-2"
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
TARGET_REGION="$AWS_REGION"
IMAGE_TAG="latest"
PLATFORM="linux/amd64"

info "Source ECR: $SOURCE_ACCOUNT_ID ($SOURCE_REGION)"
info "Target ECR: $TARGET_ACCOUNT_ID ($TARGET_REGION)"

# =============================================================================
# REPOSITORIES
# =============================================================================

REPOSITORIES=(
    "cloudanix/ecr-aws-jit-vm-sshpiper"
    "cloudanix/ecr-aws-jit-vm-proxyserver"
    "cloudanix/ecr-aws-jit-vm-logging"
)

# =============================================================================
# AUTHENTICATE TO ECR
# =============================================================================

step "ECR Authentication"

info "Authenticating to source ECR..."
aws ecr get-login-password --region "$SOURCE_REGION" | \
    docker login --username AWS --password-stdin \
    "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com" 2>/dev/null

info "Authenticating to target ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | \
    docker login --username AWS --password-stdin \
    "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com" 2>/dev/null

# =============================================================================
# SYNC EACH REPOSITORY (idempotent)
# =============================================================================

step "Sync Repositories"

for REPO in "${REPOSITORIES[@]}"; do
    info "Processing: $REPO"

    # Check if repo exists, create if not
    if aws ecr describe-repositories --region "$TARGET_REGION" \
        --repository-names "$REPO" > /dev/null 2>&1; then
        ok "  Repository exists: $REPO"
    else
        aws ecr create-repository --region "$TARGET_REGION" \
            --repository-name "$REPO" > /dev/null
        ok "  Repository created: $REPO"
    fi

    # Pull from source
    info "  Pulling from source..."
    docker pull --platform "$PLATFORM" \
        "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG" 2>/dev/null

    # Tag for target
    docker tag \
        "$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG" \
        "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"

    # Push to target
    info "  Pushing to target..."
    docker push "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG" 2>/dev/null

    ok "  Synced: $REPO"
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "All VM repositories synced successfully"
echo "OUTPUT:ECR_SYNCED=true"
