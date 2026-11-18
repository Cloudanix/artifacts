#!/usr/bin/env bash
# =============================================================================
# Step 00 — JIT VM custom roles
# =============================================================================
# Creates two tenant role definitions for this product. The names are not the
# Kubernetes roles (CDX VM SSH Access, CDX VM Read Access) and not the database
# role (JIT VM SSH Login).
#
#   CDX JIT VM SSH Access  — Entra SSH login
#   CDX JIT VM Read Access — read the VM, its NIC, and its public IP
#
# Assignable on the hub subscription. A role that already exists is left as it
# is. Step 01 assigns both to the operator.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/_helpers.sh"

validate_inputs || exit 1
az account set --subscription "$SUBSCRIPTION_ID"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

create_role() {
    local name="$1" body="$2" existing
    existing="$(az role definition list --name "$name" --query "[0].id" -o tsv)"
    if [[ -n "$existing" ]]; then
        ok "Role exists: $name"
        return 0
    fi
    local file
    file="$(mktemp)"
    printf '%s\n' "$body" > "$file"
    az role definition create --role-definition "@${file}" --only-show-errors >/dev/null
    rm -f "$file"
    ok "Role created: $name"
}

create_role "CDX JIT VM SSH Access" "$(cat <<EOF
{
  "Name": "CDX JIT VM SSH Access",
  "IsCustom": true,
  "Description": "Entra SSH login for the Cloudanix JIT VM jump host",
  "Actions": [],
  "NotActions": [],
  "DataActions": [
    "Microsoft.Compute/virtualMachines/login/action"
  ],
  "NotDataActions": [],
  "AssignableScopes": ["${SCOPE}"]
}
EOF
)"

create_role "CDX JIT VM Read Access" "$(cat <<EOF
{
  "Name": "CDX JIT VM Read Access",
  "IsCustom": true,
  "Description": "Read the Cloudanix JIT VM jump host, its NIC, and its public IP",
  "Actions": [
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/instanceView/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Network/publicIPAddresses/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": ["${SCOPE}"]
}
EOF
)"
