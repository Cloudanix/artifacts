#!/usr/bin/env bash
# =============================================================================
# Azure JIT VM — Refresh Forwarders
# =============================================================================
# Re-points the jump VM's loopback forwarders at the current private IPs of the
# proxy containers. Run it after any container group is recreated.
# Reads the saved configuration from .state.json written by ./setup.sh.
#   Usage: ./refresh-forwarders.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.state.json"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "[ERROR] $STATE_FILE not found. Run ./setup.sh first." >&2
    exit 1
fi

# Export saved config values so the step sees the same inputs as setup.sh.
while IFS='=' read -r key value; do
    export "$key=$value"
done < <(jq -r '.config | to_entries[] | "\(.key)=\(.value)"' "$STATE_FILE")

exec bash "$SCRIPT_DIR/steps/06-jump-forwarders.sh"
