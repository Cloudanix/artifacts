#!/usr/bin/env bash
# =============================================================================
# Step 04 — Runtime configuration
# =============================================================================
# Writes the values the containers read at startup into the environment
# Key Vault. The two Cloudanix credentials are read from the shell when set,
# otherwise typed here. They are not written to .state.json.
#
# Re-running adds a new version of each value. Restart the VM-proxy and
# logging container groups afterwards so they reload.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1

# read_secret_if_missing VAR LABEL
#   Uses an already-exported value. Otherwise reads it from the terminal
#   without echo. The prompt goes to the terminal, not the step log.
read_secret_if_missing() {
    local var_name="$1" label="$2" value=""
    if [[ -n "${!var_name:-}" ]]; then
        return 0
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        return 1
    fi
    while [[ -z "$value" ]]; do
        read -r -s -p "$label: " value </dev/tty 2>/dev/tty || return 1
        printf '\n' >/dev/tty
        if [[ -z "$value" ]]; then
            error "$label is required."
        fi
    done
    printf -v "$var_name" '%s' "$value"
    export "$var_name"
}

if ! read_secret_if_missing CDX_AUTH_TOKEN "Cloudanix auth token" \
    || ! read_secret_if_missing CDX_SIGNATURE_SECRET_KEY "Cloudanix signature secret"; then
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
