#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================

read -p "GCP Organization ID: " GCP_ORG_ID
[ -z "$GCP_ORG_ID" ] && { echo "Organization ID required"; exit 1; }

read -p "GCP Project ID: " GCP_PROJECT_ID
[ -z "$GCP_PROJECT_ID" ] && { echo "Project ID required"; exit 1; }

read -p "Artifact Registry Region [us-central1]: " ARTIFACTS_REGISTRY_REGION
ARTIFACTS_REGISTRY_REGION="${ARTIFACTS_REGISTRY_REGION:-us-central1}"

ARTIFACTS_REGISTRY_NAME="cdx-jit-db-artifacts"
ARTIFACTS_MANAGER_SA="cdx-artifacts-manager"

# =========================
# SET PROJECT
# =========================
gcloud config set project "$GCP_PROJECT_ID"

# =========================
# ENABLE API
# =========================
gcloud services enable artifactregistry.googleapis.com iamcredentials.googleapis.com compute.googleapis.com container.googleapis.com secretmanager.googleapis.com storage.googleapis.com cloudresourcemanager.googleapis.com servicenetworking.googleapis.com networkmanagement.googleapis.com sqladmin.googleapis.com --project=$GCP_PROJECT_ID --quiet

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
echo ""
echo "Select the scope for the custom role:"
echo "1) Organization-level (scope: $GCP_ORG_ID)"
echo "2) Project-level (scope: $GCP_PROJECT_ID)"
read -p "Enter your choice (1 or 2): " ROLE_SCOPE

case $ROLE_SCOPE in
  1)
    ROLE_NAME="cdx_jit_db_proxy_access"
    ROLE_DESCRIPTION="Cloudanix JIT DB Proxy Access Custom Role"
    ROLE_LEVEL="organization"
    
    # Check if the Custom Role already exists
    if gcloud iam roles describe "$ROLE_NAME" --organization="$GCP_ORG_ID" &> /dev/null; then
      echo "Custom Role '$ROLE_NAME' already exists at organization level. Skipping creation."
    else
      echo "Creating organization-level custom role '$ROLE_NAME'..."

      gcloud iam roles create "$ROLE_NAME" \
        --organization="$GCP_ORG_ID" \
        --title="Cloudanix JIT DB Proxy Access Custom Role" \
        --description="$ROLE_DESCRIPTION - Organization level custom role to allow fetching Proxy Info using labels and IAP tunnel access." \
        --permissions="compute.instances.get,compute.instances.getGuestAttributes,compute.instances.list,compute.instances.setMetadata,compute.networks.get,compute.projects.get,compute.subnetworks.get,compute.zones.get,compute.zones.list,iam.serviceAccounts.actAs,iam.serviceAccounts.get,iam.serviceAccounts.list,iap.tunnelDestGroups.accessViaIAP,iap.tunnelInstances.accessViaIAP,resourcemanager.projects.get,resourcemanager.projects.list" \
        --stage="GA"
    fi
    ;;
  2)
    ROLE_NAME="cdx_jit_db_proxy_access_proj"
    ROLE_DESCRIPTION="Cloudanix JIT DB Proxy Access (Project)"
    ROLE_LEVEL="project"
    
    # Check if the Custom Role already exists
    if gcloud iam roles describe "$ROLE_NAME" --project="$GCP_PROJECT_ID" &> /dev/null; then
      echo "Custom Role '$ROLE_NAME' already exists at project level. Skipping creation."
    else
      echo "Creating project-level custom role '$ROLE_NAME'..."

      gcloud iam roles create "$ROLE_NAME" \
        --project="$GCP_PROJECT_ID" \
        --title="Cloudanix JIT DB Proxy Access (Project)" \
        --description="$ROLE_DESCRIPTION - Project-level custom role to allow fetching Proxy Info using labels and IAP tunnel access." \
        --permissions="compute.instanceSettings.get,compute.instances.get,compute.instances.getGuestAttributes,compute.instances.list,compute.instances.osLogin,compute.instances.setMetadata,compute.networks.get,compute.projects.get,compute.subnetworks.get,compute.zones.get,compute.zones.list,iam.serviceAccounts.actAs,iam.serviceAccounts.get,iam.serviceAccounts.list,iap.tunnelDestGroups.accessViaIAP,iap.tunnelInstances.accessViaIAP,resourcemanager.projects.get" \
        --stage="GA"
    fi
    ;;
  *)
    echo "❌ Invalid choice. Please enter 1 or 2."
    exit 1
    ;;
esac

echo "✅ Step 5. Configured Custom Role for VM Discovery and IAP Tunnel Access (${ROLE_LEVEL}-level)"

echo ""
echo "🎉 Setup Complete!"
echo "   Custom Role: $ROLE_NAME"
echo "   Scope: ${ROLE_LEVEL^^}"

# =========================
# DONE
# =========================

exit 0
