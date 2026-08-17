#!/usr/bin/env bash
###############################################################################
# Extend CDX K8s Read Access role to additional AKS subscriptions
#
# Use this when onboarding new AKS subscriptions AFTER initial setup.
# It updates the AssignableScopes of "CDX K8s Read Access" to include
# the new subscription(s), making the role assignable there.
#
# Idempotent — skips subscriptions already in scope.
###############################################################################
set -euo pipefail

ROLE_NAME="CDX K8s Read Access"

echo "=== Extend '$ROLE_NAME' to Additional AKS Subscriptions ==="
echo ""
echo "This adds new subscription(s) to the role's AssignableScopes so it can"
echo "be assigned in those subscriptions for AKS access."
echo ""

read -rp "New AKS Subscription IDs to add (comma separated): " INPUT_NEW_SUBS
if [[ -z "$INPUT_NEW_SUBS" ]]; then
    echo "ERROR: At least one subscription ID is required."
    exit 1
fi

###############################################################################
# Get current role definition
###############################################################################
echo ""
echo "=== Fetching current role definition ==="

ROLE_DEF=$(az role definition list --name "$ROLE_NAME" --query "[0]" -o json 2>/dev/null)

if [[ -z "$ROLE_DEF" || "$ROLE_DEF" == "null" ]]; then
    echo "ERROR: Role '$ROLE_NAME' not found."
    echo "  Run 01-create-custom-roles.sh first to create the roles."
    exit 1
fi

# Extract current assignable scopes
CURRENT_SCOPES=$(echo "$ROLE_DEF" | python3 -c "
import sys, json
role = json.load(sys.stdin)
scopes = role.get('assignableScopes', [])
for s in scopes:
    print(s)
")

echo "Current AssignableScopes:"
echo "$CURRENT_SCOPES" | sed 's/^/  /'

###############################################################################
# Build updated scopes (add new, skip duplicates)
###############################################################################
echo ""
echo "=== Adding new subscriptions ==="

# Start with current scopes
UPDATED_SCOPES=()
while IFS= read -r scope; do
    [[ -n "$scope" ]] && UPDATED_SCOPES+=("$scope")
done <<< "$CURRENT_SCOPES"

# Add new subscriptions if not already present
IFS=',' read -ra NEW_SUB_ARRAY <<< "$INPUT_NEW_SUBS"
ADDED=0
for sub in "${NEW_SUB_ARRAY[@]}"; do
    sub=$(echo "$sub" | xargs)  # trim whitespace
    NEW_SCOPE="/subscriptions/${sub}"

    # Check if already in scopes
    ALREADY_EXISTS=false
    for existing in "${UPDATED_SCOPES[@]}"; do
        if [[ "$existing" == "$NEW_SCOPE" ]]; then
            ALREADY_EXISTS=true
            break
        fi
    done

    if [[ "$ALREADY_EXISTS" == true ]]; then
        echo "  [skip] $sub — already in AssignableScopes"
    else
        UPDATED_SCOPES+=("$NEW_SCOPE")
        echo "  [add]  $sub"
        ADDED=$((ADDED + 1))
    fi
done

if [[ $ADDED -eq 0 ]]; then
    echo ""
    echo "No new subscriptions to add. Role is already configured."
    exit 0
fi

###############################################################################
# Build updated role JSON and apply
# Uses camelCase keys + "name" (GUID) field required by Azure CLI 2.87+
###############################################################################
echo ""
echo "=== Updating role definition ==="

# Build the updated JSON using python3 for reliability
# This dynamically preserves existing permissions and only changes assignableScopes
echo "$ROLE_DEF" | python3 -c "
import sys, json

role = json.load(sys.stdin)
scopes = sys.argv[1:]

# Build the update payload with the exact fields Azure CLI expects
update = {
    'name': role['name'],                    # GUID — required by CLI 2.87+
    'roleName': role['roleName'],
    'description': role.get('description', ''),
    'type': 'CustomRole',
    'permissions': role.get('permissions', []),
    'assignableScopes': scopes
}

json.dump(update, open('/tmp/cdx-k8s-read-access-update.json', 'w'), indent=2)
" "${UPDATED_SCOPES[@]}"

echo "Update payload:"
cat /tmp/cdx-k8s-read-access-update.json | sed 's/^/  /'
echo ""

az role definition update --role-definition @/tmp/cdx-k8s-read-access-update.json --output none
rm -f /tmp/cdx-k8s-read-access-update.json

echo "Role updated successfully."

###############################################################################
# Summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Role Scope Extension Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Role: $ROLE_NAME"
echo "  Updated AssignableScopes:"
for scope in "${UPDATED_SCOPES[@]}"; do
    echo "    - $scope"
done
echo ""
echo "  The role can now be assigned in all listed subscriptions."
echo ""
echo "  Next steps (for each new AKS subscription):"
echo "    → Run 03-setup-peering-role-and-dns.sh to set up VNet peering + DNS"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
