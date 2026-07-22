#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================
read -p "GCP Project ID: " GCP_PROJECT_ID
[ -z "$GCP_PROJECT_ID" ] && { echo "Project ID required"; exit 1; }

read -p "Artifact Registry Region [us-central1]: " ARTIFACTS_REGISTRY_REGION
ARTIFACTS_REGISTRY_REGION="${ARTIFACTS_REGISTRY_REGION:-us-central1}"

read -p "Artifact Registry Sync User Email: " ACR_SYNC_USER_EMAIL
[ -z "$ACR_SYNC_USER_EMAIL" ] && { echo "Artifact Registry Sync User Email required"; exit 1; }

ARTIFACTS_MANAGER_SA="cdx-artifacts-manager"

# CREATE ARTIFACT REGISTRY
# =========================
gcloud iam service-accounts add-iam-policy-binding \
  "$ARTIFACTS_MANAGER_SA@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
  --member="user:$ACR_SYNC_USER_EMAIL" \
  --role="roles/iam.serviceAccountTokenCreator"

echo "✅ Granted Permission to impersonate ACR Manager Service Account"
