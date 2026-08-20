#!/usr/bin/env bash
# =============================================================================
# Step: Sync ECR Images
# =============================================================================
# Pulls container images from the Cloudanix source ECR and pushes them to the
# customer's target ECR. Creates ECR repositories if they don't exist.
#
# Required env vars:
#   AWS_REGION, IMAGE_TAG, ENABLE_DAM
#
# Outputs:
#   OUTPUT:ECR_SYNCED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
source "$LIB_DIR/common.sh"

# Validate required env vars
require_env AWS_REGION IMAGE_TAG ENABLE_DAM || exit 1

# =============================================================================
# CONFIGURATION
# =============================================================================

SOURCE_ACCOUNT_ID="774118602354"
SOURCE_REGION="us-east-2"
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
TARGET_REGION="$AWS_REGION"
PLATFORM="linux/amd64"

info "Source ECR: $SOURCE_ACCOUNT_ID ($SOURCE_REGION)"
info "Target ECR: $TARGET_ACCOUNT_ID ($TARGET_REGION)"
info "Image tag: $IMAGE_TAG"
info "DAM enabled: $ENABLE_DAM"

# =============================================================================
# DETERMINE REPOSITORIES
# =============================================================================

REPOSITORIES=(
    "cloudanix/ecr-aws-jit-proxy-sql"
    "cloudanix/ecr-aws-jit-query-logging"
    "cloudanix/ecr-aws-jit-proxy-server"
)

if [[ "$ENABLE_DAM" == "true" ]]; then
    REPOSITORIES+=(
        "cloudanix/ecr-aws-jit-dam-server"
        "cloudanix/ecr-aws-jit-postgresql"
    )
fi

# =============================================================================
# AUTHENTICATE TO ECR
# =============================================================================

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

for REPO in "${REPOSITORIES[@]}"; do
    info "Processing: $REPO"

    # Check if repo exists, create if not (idempotent)
    if aws ecr describe-repositories --region "$TARGET_REGION" \
        --repository-names "$REPO" > /dev/null 2>&1; then
        ok "  Repository exists: $REPO"
    else
        aws ecr create-repository --region "$TARGET_REGION" \
            --repository-name "$REPO" > /dev/null
        ok "  Repository created: $REPO"
    fi

    # --- Idempotent check: skip if target already has this tag ---
    TARGET_DIGEST=$(aws ecr describe-images --region "$TARGET_REGION" \
        --repository-name "$REPO" \
        --image-ids imageTag="$IMAGE_TAG" \
        --query "imageDetails[0].imageDigest" --output text 2>/dev/null || echo "")

    if [[ -n "$TARGET_DIGEST" && "$TARGET_DIGEST" != "None" ]]; then
        ok "  Already exists in target ECR: $REPO (skipping)"
        continue
    fi

    # --- Pull from source ---
    SOURCE_IMAGE="$SOURCE_ACCOUNT_ID.dkr.ecr.$SOURCE_REGION.amazonaws.com/$REPO:$IMAGE_TAG"
    TARGET_IMAGE_TAG="$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:$IMAGE_TAG"
    TARGET_IMAGE_LATEST="$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com/$REPO:latest"

    info "  Pulling $SOURCE_IMAGE"
    docker pull --platform "$PLATFORM" "$SOURCE_IMAGE" || {
        error "  Failed to pull image. Ensure source ECR grants access to account $TARGET_ACCOUNT_ID"
        exit 1
    }

    # Tag for target
    docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE_TAG"
    docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE_LATEST"

    # Push to target
    info "  Pushing to target..."
    docker push "$TARGET_IMAGE_TAG" || {
        error "  Failed to push $IMAGE_TAG tag"; exit 1
    }
    docker push "$TARGET_IMAGE_LATEST" || {
        error "  Failed to push latest tag"; exit 1
    }

    ok "  Synced: $REPO"

    # --- Clean up local images to free disk space ---
    # Critical for constrained environments like CloudShell (1GB disk)
    docker rmi -f $(docker images -q) 2>/dev/null || true
    docker system prune -af > /dev/null 2>&1 || true
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "All repositories synced successfully"
echo "OUTPUT:ECR_SYNCED=true"
echo "OUTPUT:TARGET_ECR_PREFIX=${TARGET_ACCOUNT_ID}.dkr.ecr.${TARGET_REGION}.amazonaws.com"
