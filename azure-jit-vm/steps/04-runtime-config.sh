#!/usr/bin/env bash
# =============================================================================
# Step 04 — Runtime configuration
# =============================================================================
# Writes the values the containers read at startup into the environment
# Key Vault. The two Cloudanix credentials come from the shell only.
#
#   export CDX_AUTH_TOKEN='...'
#   export CDX_SIGNATURE_SECRET_KEY='...'
#
# Re-running adds a new version of each value. Restart the VM-proxy and
# logging container groups afterwards so they reload.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1

if ! require_env CDX_AUTH_TOKEN CDX_SIGNATURE_SECRET_KEY; then
    error "Export CDX_AUTH_TOKEN and CDX_SIGNATURE_SECRET_KEY in this shell, then re-run."
    error "They are not saved to disk."
    exit 1
fi

set_secret "$KV_ENV" "CDX-APP-ENV" "PRODUCTION"
set_secret "$KV_ENV" "CDX-LOG-LEVEL" "INFO"
set_secret "$KV_ENV" "CDX-DC" "$CDX_DC"
set_secret "$KV_ENV" "CDX-API-BASE" "$CDX_API_BASE"
set_secret "$KV_ENV" "CDX-AUTH-TOKEN" "$CDX_AUTH_TOKEN"
set_secret "$KV_ENV" "CDX-SIGNATURE-SECRET-KEY" "$CDX_SIGNATURE_SECRET_KEY"
set_secret "$KV_ENV" "CDX-SENTRY-DSN" "none"
set_secret "$KV_ENV" "CDX-PROXY-SERVER-VERSION" "$IMAGE_TAG"
set_secret "$KV_ENV" "CDX-LOG-MANAGER-VERSION" "$IMAGE_TAG"
set_secret "$KV_ENV" "CDX-LOGGING-AZURE-CONTAINER" "$LOG_CONTAINER"
set_secret "$KV_ENV" "AZURE-STORAGE-ACCOUNT-URL" "https://${STORAGE}.blob.core.windows.net/"
