#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================

# Customer Artifact Registry details
read -p "GCP Project ID: " GCP_PROJECT_ID
[ -z "$GCP_PROJECT_ID" ] && { echo "Project ID required"; exit 1; }

read -p "Artifact Registry Region [us-central1]: " GCP_PROJECT_REGION
GCP_PROJECT_REGION="${GCP_PROJECT_REGION:-us-central1}"

ARTIFACTS_REGISTRY_NAME="cdx-jit-db-artifacts"

# Cloudanix Artifact Registry details
CDX_GCP_PROJECT="cloudanix-app"
CDX_ARTIFACTS_REGISTRY_REGION="us-central1"
CDX_ARTIFACTS_REGISTRY_NAME="cdx-jit-db-artifacts"

ARTIFACTS_MANAGER_SA="cdx-artifacts-manager"

prompt_with_options() {
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

echo ""
ENABLE_DAM=false
if prompt_with_options "Enable Database Activity Monitoring (DAM)?" "n"; then
    ENABLE_DAM=true
    echo "DAM will be enabled"
else
    echo "DAM will not be enabled"
fi

# =========================
# AUTH GCP ARTIFACTS REGISTRY
# =========================
# Step 1: Authenticate as yourself
# TODO: use - gcloud auth login --no-launch-browser
gcloud auth login

# Step 2: Impersonate CUSTOMER sync SA
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$ARTIFACTS_MANAGER_SA@$GCP_PROJECT_ID.iam.gserviceaccount.com"

# Step 3: Configure Docker (this cascades impersonation)
gcloud auth configure-docker "$GCP_PROJECT_REGION-docker.pkg.dev"

# Images to sync
IMAGES=(
  "gcp-ar-jit-proxy-sql"
  "gcp-ar-jit-query-logging"
  "gcp-ar-jit-proxy-server")

# Add DAM images if enabled
if [ "$ENABLE_DAM" = true ]; then
    IMAGES+=(
      "gcp-ar-jit-dam-server"
      "gcp-ar-jit-postgresql"
    )
fi


# =========================
# AUTH DOCKER
# =========================
# gcloud auth configure-docker \
#   ${CDX_ARTIFACTS_REGISTRY_REGION}-docker.pkg.dev \
#   ${GCP_PROJECT_REGION}-docker.pkg.dev

# =========================
# SYNC IMAGES
# =========================
for IMAGE in "${IMAGES[@]}"; do
  NAME="${IMAGE%%:*}"
  TAG="${IMAGE##*:}"

  CDX_IMAGE="${CDX_ARTIFACTS_REGISTRY_REGION}-docker.pkg.dev/${CDX_GCP_PROJECT}/${CDX_ARTIFACTS_REGISTRY_NAME}/${IMAGE}"
  CUSTOMER_IMAGE="${GCP_PROJECT_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACTS_REGISTRY_NAME}/${IMAGE}"

  echo "🔄 Syncing ${IMAGE}"

  docker pull  --platform=linux/amd64 "$CDX_IMAGE"
  docker tag "$CDX_IMAGE" "$CUSTOMER_IMAGE"
  docker push "$CUSTOMER_IMAGE"

done

echo "✅ Artifacts Registry Images sync complete"
