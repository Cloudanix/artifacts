#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG
# =========================
GCP_PROJECT_ID="$1"
ARTIFACTS_REGISTRY_REGION="${2:-"us-central1"}"
ARTIFACTS_REGISTRY_NAME="cdx-jit-db-artifacts"
ARTIFACTS_MANAGER_SA="cdx-artifacts-manager"

ACR_SYNC_USER_EMAIL="$3"

# =========================
# CREATE ARTIFACT REGISTRY
# =========================
gcloud iam service-accounts add-iam-policy-binding \
  "$ARTIFACTS_MANAGER_SA@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
  --member="user:$ACR_SYNC_USER_EMAIL" \
  --role="roles/iam.serviceAccountTokenCreator"

echo "✅ Granted Permission to impersonate ACR Manager Service Account"
