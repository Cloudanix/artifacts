#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
# Download the complete Cloudanix AWS Wazuh playbook and start its setup.
REPO="${CDX_REPO:-Cloudanix/artifacts}"
REF="${CDX_REPO_REF:-main}"
INSTALL_DIR="${CDX_INSTALL_DIR:-${HOME}/.cloudanix/aws-customer-wazuh}"
ARCHIVE_URL="${CDX_ARCHIVE_URL:-https://codeload.github.com/${REPO}/tar.gz/${REF}}"

for tool in curl tar mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool not found: ${tool}" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -r "$TMP_DIR"' EXIT
ARCHIVE="${TMP_DIR}/artifacts.tar.gz"

echo "==> Downloading Cloudanix AWS Wazuh (${REF})"
DOWNLOAD_URL="$ARCHIVE_URL"
if [[ "$ARCHIVE_URL" == http://* || "$ARCHIVE_URL" == https://* ]]; then
  DOWNLOAD_URL="${ARCHIVE_URL}?cdxcb=$(date +%s)"
fi
curl -fsSL --retry 3 --connect-timeout 15 \
  -H 'Cache-Control: no-cache' \
  "$DOWNLOAD_URL" \
  -o "$ARCHIVE"

TOP_DIR="$(tar -tzf "$ARCHIVE" | awk -F/ 'NR == 1 { top=$1 } END { print top }')"
[[ -n "$TOP_DIR" ]] || { echo "error: invalid archive" >&2; exit 1; }
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_DIR="${TMP_DIR}/${TOP_DIR}/aws-customer-wazuh"

for required in setup.sh infra/deploy.sh wazuh/apply.sh; do
  [[ -f "${SOURCE_DIR}/${required}" ]] || {
    echo "error: archive is missing aws-customer-wazuh/${required}" >&2
    exit 1
  }
done

SAVED_PARAMS=""
if [[ -f "${INSTALL_DIR}/infra/parameters.json" ]]; then
  SAVED_PARAMS="${TMP_DIR}/parameters.json"
  cp "${INSTALL_DIR}/infra/parameters.json" "$SAVED_PARAMS"
fi
if [[ -e "$INSTALL_DIR" ]]; then
  BACKUP="${INSTALL_DIR}.previous-$(date +%Y%m%d%H%M%S)"
  mv "$INSTALL_DIR" "$BACKUP"
  echo "==> Previous install saved at ${BACKUP}"
fi
mkdir -p "$(dirname "$INSTALL_DIR")"
cp -R "$SOURCE_DIR" "$INSTALL_DIR"
if [[ -n "$SAVED_PARAMS" ]]; then
  cp "$SAVED_PARAMS" "${INSTALL_DIR}/infra/parameters.json"
  chmod 600 "${INSTALL_DIR}/infra/parameters.json"
fi
chmod +x "${INSTALL_DIR}/setup.sh" \
  "${INSTALL_DIR}/infra/"*.sh \
  "${INSTALL_DIR}/wazuh/apply.sh" \
  "${INSTALL_DIR}/wazuh/base/certs/indexer_cluster/generate_certs.sh" \
  "${INSTALL_DIR}/wazuh/base/certs/dashboard_http/generate_certs.sh"

echo "==> Installed files at ${INSTALL_DIR}"
if [[ "${CDX_DOWNLOAD_ONLY:-false}" == "true" ]]; then
  echo "Run: ${INSTALL_DIR}/setup.sh"
  exit 0
fi
exec "${INSTALL_DIR}/setup.sh"
