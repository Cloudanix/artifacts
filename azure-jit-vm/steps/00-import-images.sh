#!/usr/bin/env bash
# =============================================================================
# Step 00 — Import proxy images
# =============================================================================
# Copies the three VM images from the Cloudanix central registry into
# IMAGE_REGISTRY. When that registry is already cdxjitcentral, the images are
# there and this step does nothing. Keep the server value in sync with
# azure-jit-db/image-tags.sh.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

CENTRAL_ACR_SERVER="cdxjitcentral.azurecr.io"
CUSTOMER_ACR="${IMAGE_REGISTRY%%.*}"

if [[ "$CUSTOMER_ACR" == "cdxjitcentral" ]]; then
    ok "Images stay in cdxjitcentral. Nothing to copy."
    exit 0
fi

import_image() {
    local repo="$1"
    if az acr repository show --name "$CUSTOMER_ACR" --image "${repo}:${IMAGE_TAG}" -o none 2>/dev/null; then
        ok "Already present: ${repo}:${IMAGE_TAG}"
        return 0
    fi
    info "Importing ${repo}:${IMAGE_TAG} from ${CENTRAL_ACR_SERVER}"
    az acr import \
        --name "$CUSTOMER_ACR" \
        --source "${CENTRAL_ACR_SERVER}/${repo}:${IMAGE_TAG}" \
        --image "${repo}:${IMAGE_TAG}"
    ok "Imported ${repo}:${IMAGE_TAG}"
}

import_image "$SSHPIPER_IMAGE"
import_image "$VMPROXY_IMAGE"
import_image "$LOGGING_IMAGE"
