#!/usr/bin/env bash
# =============================================================================
# Step: Sync ECR Images (HIDDEN — only runs via ./setup.sh --sync-ecr)
# =============================================================================
# Legacy image-distribution path. Pulls container images from the Cloudanix
# PUBLIC ECR registry and pushes them into the customer's PRIVATE ECR under the
# original repository names (cloudanix/ecr-aws-jit-<name>). Creates the target
# repositories if they don't exist.
#
# The DEFAULT customer flow does NOT use this step — it relies on an ECR
# pull-through cache instead (no Docker, no manual sync). This step exists only
# for environments that cannot use a pull-through cache and is invoked
# explicitly with the --sync-ecr flag.
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

TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
TARGET_REGION="$AWS_REGION"
PLATFORM="linux/amd64"

info "Source (public) ECR: ${CDX_PUBLIC_ECR_HOST}/${CDX_PUBLIC_ECR_ALIAS}/cloudanix"
info "Target (private) ECR: $TARGET_ACCOUNT_ID ($TARGET_REGION)"
info "Image tag: $IMAGE_TAG"
info "DAM enabled: $ENABLE_DAM"

# =============================================================================
# DETERMINE REPOSITORIES
# =============================================================================
# Short names map: public source (cloudanix/aws-jit-<short>) -> private target
# (cloudanix/ecr-aws-jit-<short>).

SHORT_NAMES=(
    "proxy-sql"
    "query-logging"
    "proxy-server"
)

if [[ "$ENABLE_DAM" == "true" ]]; then
    SHORT_NAMES+=(
        "dam-server"
        "postgresql"
    )
fi

# =============================================================================
# AUTHENTICATE TO ECR
# =============================================================================
# Public ECR pulls are anonymous, but ECR Public enforces higher rate limits
# for authenticated pulls. Authenticate best-effort (never fatal).
info "Authenticating to public ECR (best-effort)..."
aws ecr-public get-login-password --region us-east-1 2>/dev/null | \
    docker login --username AWS --password-stdin "$CDX_PUBLIC_ECR_HOST" 2>/dev/null || \
    warn "  Public ECR login skipped (anonymous pulls will be used)"

info "Authenticating to target ECR..."
aws ecr get-login-password --region "$TARGET_REGION" | \
    docker login --username AWS --password-stdin \
    "$TARGET_ACCOUNT_ID.dkr.ecr.$TARGET_REGION.amazonaws.com" 2>/dev/null

# =============================================================================
# SYNC EACH REPOSITORY (idempotent)
# =============================================================================

for SHORT in "${SHORT_NAMES[@]}"; do
    TARGET_REPO="$(cdx_private_repo "$SHORT")"
    SOURCE_IMAGE="${CDX_PUBLIC_ECR_HOST}/${CDX_PUBLIC_ECR_ALIAS}/$(cdx_public_repo "$SHORT"):${IMAGE_TAG}"
    TARGET_IMAGE="${TARGET_ACCOUNT_ID}.dkr.ecr.${TARGET_REGION}.amazonaws.com/${TARGET_REPO}:${IMAGE_TAG}"

    info "Processing: $TARGET_REPO"

    # Check if repo exists, create if not (idempotent)
    if aws ecr describe-repositories --region "$TARGET_REGION" \
        --repository-names "$TARGET_REPO" > /dev/null 2>&1; then
        ok "  Repository exists: $TARGET_REPO"
    else
        aws ecr create-repository --region "$TARGET_REGION" \
            --repository-name "$TARGET_REPO" > /dev/null
        ok "  Repository created: $TARGET_REPO"
    fi

    # --- Idempotent check: skip if target already has this tag ---
    TARGET_DIGEST=$(aws ecr describe-images --region "$TARGET_REGION" \
        --repository-name "$TARGET_REPO" \
        --image-ids imageTag="$IMAGE_TAG" \
        --query "imageDetails[0].imageDigest" --output text 2>/dev/null || echo "")

    if [[ -n "$TARGET_DIGEST" && "$TARGET_DIGEST" != "None" ]]; then
        ok "  Already exists in target ECR: $TARGET_REPO:$IMAGE_TAG (skipping)"
        continue
    fi

    # --- Pull from public source ---
    info "  Pulling $SOURCE_IMAGE"
    docker pull --platform "$PLATFORM" "$SOURCE_IMAGE" || {
        error "  Failed to pull image from public ECR: $SOURCE_IMAGE"
        error "  Ensure tag '$IMAGE_TAG' has been published to the public repo."
        exit 1
    }

    # Tag for target (pinned tag only — we intentionally no longer push :latest)
    docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"

    # Push to target
    info "  Pushing to target: $TARGET_IMAGE"
    docker push "$TARGET_IMAGE" || {
        error "  Failed to push $IMAGE_TAG tag"; exit 1
    }

    ok "  Synced: $TARGET_REPO:$IMAGE_TAG"

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
