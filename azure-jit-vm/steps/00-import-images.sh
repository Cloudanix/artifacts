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

# image_platform_present ACR REPO TAG
#   A tag can point at a manifest list whose platform image was never copied.
#   ACI then reports InaccessibleImage. Require every referenced manifest.
image_platform_present() {
    local acr="$1" repo="$2" tag="$3" manifest digest
    manifest="$(az acr manifest show --registry "$acr" --name "${repo}:${tag}" -o json 2>/dev/null)" || return 1
    local digests
    digests="$(printf '%s' "$manifest" | jq -r '.manifests[]?.digest // empty')"
    if [[ -z "$digests" ]]; then
        return 0
    fi
    while IFS= read -r digest; do
        [[ -z "$digest" ]] && continue
        az acr manifest show --registry "$acr" --name "${repo}@${digest}" -o none 2>/dev/null || return 1
    done <<< "$digests"
}

if [[ "$CUSTOMER_ACR" == "cdxjitcentral" ]]; then
    missing=0
    for repo in "$SSHPIPER_IMAGE" "$VMPROXY_IMAGE" "$LOGGING_IMAGE"; do
        if image_platform_present "$CUSTOMER_ACR" "$repo" "$IMAGE_TAG"; then
            ok "Pullable: ${repo}:${IMAGE_TAG}"
        else
            error "Incomplete image in cdxjitcentral: ${repo}:${IMAGE_TAG}"
            error "The tag exists, but its platform manifest is missing. Re-import that image into the central registry."
            missing=1
        fi
    done
    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
    ok "Images stay in cdxjitcentral. Nothing to copy."
    exit 0
fi

import_image() {
    local repo="$1" attempt
    if image_platform_present "$CUSTOMER_ACR" "$repo" "$IMAGE_TAG"; then
        ok "Already present: ${repo}:${IMAGE_TAG}"
        return 0
    fi
    for attempt in 1 2; do
        info "Importing ${repo}:${IMAGE_TAG} from ${CENTRAL_ACR_SERVER} (attempt ${attempt})"
        az acr import \
            --name "$CUSTOMER_ACR" \
            --source "${CENTRAL_ACR_SERVER}/${repo}:${IMAGE_TAG}" \
            --image "${repo}:${IMAGE_TAG}" \
            --force
        if image_platform_present "$CUSTOMER_ACR" "$repo" "$IMAGE_TAG"; then
            ok "Imported ${repo}:${IMAGE_TAG}"
            return 0
        fi
    done
    error "Import of ${repo}:${IMAGE_TAG} left a tag without its platform image."
    return 1
}

import_image "$SSHPIPER_IMAGE" || exit 1
import_image "$VMPROXY_IMAGE" || exit 1
import_image "$LOGGING_IMAGE" || exit 1
