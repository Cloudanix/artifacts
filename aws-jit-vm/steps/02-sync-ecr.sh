#!/usr/bin/env bash
# =============================================================================
# Step: Sync ECR Images (VM) — HIDDEN, only runs via ./setup.sh --sync-ecr
# =============================================================================
# Legacy image-distribution path for the VM images (sshpiper, proxyserver,
# logging). Pulls from the Cloudanix PUBLIC ECR registry and pushes into the
# customer's PRIVATE ECR under the original repository names
# (cloudanix/ecr-aws-jit-vm-<name>). Creates target repositories if missing.
#
# The DEFAULT customer flow does NOT use this step — it relies on an ECR
# pull-through cache instead. This step is invoked explicitly with --sync-ecr.
#
# Required env vars:
#   AWS_REGION
# Optional:
#   IMAGE_TAG (defaults to the pinned VM image tag)
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

TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
TARGET_REGION="$AWS_REGION"
IMAGE_TAG="${IMAGE_TAG:-${CDX_VM_IMAGE_TAG:-v0.3.31}}"
PLATFORM="linux/amd64"

info "Source (public) ECR: ${CDX_PUBLIC_ECR_HOST}/${CDX_PUBLIC_ECR_ALIAS}/cloudanix"
info "Target (private) ECR: $TARGET_ACCOUNT_ID ($TARGET_REGION)"
info "Image tag: $IMAGE_TAG"

# =============================================================================
# REPOSITORIES (short names)
# =============================================================================

SHORT_NAMES=(
    "vm-sshpiper"
    "vm-proxyserver"
    "vm-logging"
)

# =============================================================================
# AUTHENTICATE TO ECR
# =============================================================================

step "ECR Authentication"

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

step "Sync Repositories"

for SHORT in "${SHORT_NAMES[@]}"; do
    TARGET_REPO="$(cdx_private_repo "$SHORT")"
    SOURCE_IMAGE="${CDX_PUBLIC_ECR_HOST}/${CDX_PUBLIC_ECR_ALIAS}/$(cdx_public_repo "$SHORT"):${IMAGE_TAG}"
    TARGET_IMAGE="${TARGET_ACCOUNT_ID}.dkr.ecr.${TARGET_REGION}.amazonaws.com/${TARGET_REPO}:${IMAGE_TAG}"

    info "Processing: $TARGET_REPO"

    # Check if repo exists, create if not
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
        error "  Failed to pull image from public ECR: $SOURCE_IMAGE"; exit 1
    }

    # Tag for target
    docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"

    # Push to target
    info "  Pushing to target: $TARGET_IMAGE"
    docker push "$TARGET_IMAGE" || {
        error "  Failed to push $TARGET_REPO"; exit 1
    }

    ok "  Synced: $TARGET_REPO:$IMAGE_TAG"

    # --- Clean up local images to free disk space ---
    docker rmi -f $(docker images -q) 2>/dev/null || true
    docker system prune -af > /dev/null 2>&1 || true
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "All VM repositories synced successfully"
echo "OUTPUT:ECR_SYNCED=true"
