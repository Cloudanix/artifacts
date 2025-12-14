#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================
GCP_ORG_ID="$1"
GCP_PROJECT_ID="$2"
ARTIFACTS_REGISTRY_REGION="${3:-"us-central1"}"
ARTIFACTS_REGISTRY_NAME="cdx-jit-db-artifacts"
ARTIFACTS_MANAGER_SA="cdx-artifacts-manager"

# =========================
# SET PROJECT
# =========================
gcloud config set project "$GCP_PROJECT_ID"

# =========================
# ENABLE API
# =========================
gcloud services enable artifactregistry.googleapis.com iamcredentials.googleapis.com compute.googleapis.com container.googleapis.com secretmanager.googleapis.com storage.googleapis.com cloudresourcemanager.googleapis.com servicenetworking.googleapis.com networkmanagement.googleapis.com sqladmin.googleapis.com --project=$PROJECT_ID --quiet

sleep 60

echo "✅ Step 1. APIs enabled"

# =========================
# CREATE ARTIFACT REGISTRY
# =========================
# Check if the Artifact Registry already exists
if gcloud artifacts repositories describe "$ARTIFACTS_REGISTRY_NAME" --location="$ARTIFACTS_REGISTRY_REGION" &> /dev/null; then
  echo "Artifact Registry '$ARTIFACTS_REGISTRY_NAME' already exists in region '$ARTIFACTS_REGISTRY_REGION'. Skipping creation."
else
  echo "Artifact Registry '$ARTIFACTS_REGISTRY_NAME' does not exist. Creating..."

  gcloud artifacts repositories create "$ARTIFACTS_REGISTRY_NAME" \
    --repository-format=docker \
    --location="$ARTIFACTS_REGISTRY_REGION" \
    --description="Cloudanix JIT DB Artifacts Repository" \
    --labels="env=production,owner=cloudanix,purpose=cdx-jit-db-artifacts"
fi


echo "✅ Step 2. Artifact Registry Configured"


# =========================
# CREATE Artifact Registry Sync Service Account
# =========================
# Check if the Service Account already exists
if gcloud iam service-accounts describe "$ARTIFACTS_MANAGER_SA@$GCP_PROJECT_ID.iam.gserviceaccount.com" &> /dev/null; then
  echo "Service Account '$ARTIFACTS_MANAGER_SA' already exists. Skipping creation."
else
  echo "Service Account '$ARTIFACTS_MANAGER_SA' does not exist. Creating..."

  gcloud iam service-accounts create "$ARTIFACTS_MANAGER_SA" \
    --display-name="Cloudanix Artifact Registry Sync Service Account"
fi

echo "✅ Step 3. Service Account Configured"


# =========================
# GRANT READER & WRITER ACCESS TO REPO
# =========================
gcloud artifacts repositories add-iam-policy-binding "$ARTIFACTS_REGISTRY_NAME" \
  --location="$ARTIFACTS_REGISTRY_REGION" \
  --member="serviceAccount:${ARTIFACTS_MANAGER_SA}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.admin"

echo "✅ Step 4. Granted Permissions to Service Account"


# =========================
# Create Custom Role for VM Discovery and IAP Tunnel Access
# =========================
# Check if the Custom Role already exists
if gcloud iam roles describe "cdx_jit_db_proxy_access" --organization="$GCP_ORG_ID" &> /dev/null; then
  echo "Custom Role 'cdx_jit_db_proxy_access' already exists. Skipping creation."
else
  echo "Custom Role 'cdx_jit_db_proxy_access' does not exist. Creating..."

  gcloud iam roles create "cdx_jit_db_proxy_access" \
    --organization=$GCP_ORG_ID \
    --title="Cloudanix JIT DB Proxy Access Custom Role" \
    --description="Custom role to allow fetching Proxy Info using labels and IAP tunnel access." \
    --permissions="compute.projects.get,compute.instances.list,compute.instances.get,compute.instances.getGuestAttributes,compute.zones.list,compute.zones.get,compute.networks.get,compute.subnetworks.get,iap.tunnelDestGroups.accessViaIAP,iap.tunnelInstances.accessViaIAP" \
    --stage="GA"
fi

echo "✅ Step 5. Configured Custom Role for VM Discovery and IAP Tunnel Access"

echo "🎉 Setup Complete!"

# =========================
# DONE
# =========================

exit 0
