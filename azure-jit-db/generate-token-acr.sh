#!/bin/bash
set -e

# ============================================================
# Generate Pull-Only ACR Token for Customer
# Usage: ./generate-customer-token.sh <customer-name> [days]
# Example: ./generate-customer-token.sh acme-corp 7
# ============================================================

ACR_NAME="cdxjitacr111"
CUSTOMER_NAME="${1}"
TOKEN_DAYS="${2:-7}"

if [ -z "$CUSTOMER_NAME" ]; then
  echo "Usage: $0 <customer-name> [days]"
  echo ""
  echo "Examples:"
  echo "  $0 acme-corp        # 7 days (default)"
  echo "  $0 acme-corp 14     # 14 days"
  echo ""
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating Pull-Only ACR Token"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Customer:  $CUSTOMER_NAME"
echo "Valid for: $TOKEN_DAYS days"
echo ""

# Check if scope map exists, create if not
SCOPE_MAP_EXISTS=$(az acr scope-map show \
  --name customer-pull-only \
  --registry $ACR_NAME \
  --query name -o tsv 2>/dev/null || echo "")

if [ -z "$SCOPE_MAP_EXISTS" ]; then
  echo "Creating pull-only scope map (one-time setup)..."
  
  az acr scope-map create \
    --name customer-pull-only \
    --registry $ACR_NAME \
    --repository cloudanix/ecr-aws-jit-proxy-sql content/read \
    --repository cloudanix/ecr-aws-jit-proxy-server content/read \
    --repository cloudanix/ecr-aws-jit-query-logging content/read \
    --repository cloudanix/ecr-aws-jit-dam-server content/read \
    --repository cloudanix/ecr-aws-jit-postgresql content/read \
    --description "Pull-only access for customer onboarding" \
    --output none
  
  echo " Scope map created"
fi

# Create token (or update if exists)
echo "Creating token..."

az acr token create \
  --name "${CUSTOMER_NAME}-sync" \
  --registry $ACR_NAME \
  --scope-map customer-pull-only \
  --expiration-in-days $TOKEN_DAYS \
  --output none 2>/dev/null || \
  az acr token update \
    --name "${CUSTOMER_NAME}-sync" \
    --registry $ACR_NAME \
    --expiration-in-days $TOKEN_DAYS \
    --output none

echo " Token created/updated"

# Generate password
echo "Generating credentials..."

TOKEN_CREDS=$(az acr token credential generate \
  --name "${CUSTOMER_NAME}-sync" \
  --registry $ACR_NAME \
  --expiration-in-days $TOKEN_DAYS \
  --output json)

TOKEN_USERNAME=$(echo $TOKEN_CREDS | jq -r '.username')
TOKEN_PASSWORD=$(echo $TOKEN_CREDS | jq -r '.passwords[0].value')
TOKEN_EXPIRY=$(echo $TOKEN_CREDS | jq -r '.passwords[0].expiry')

# Display credentials
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Token Generated Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Customer:  $CUSTOMER_NAME"
echo "Username:  $TOKEN_USERNAME"
echo "Password:  $TOKEN_PASSWORD"
echo "Expires:   $TOKEN_EXPIRY"
echo ""
echo "Access:"
echo "   Pull-only (cannot push)"
echo "   Auto-expires in $TOKEN_DAYS days"
echo "   Scoped to JIT images only"
echo ""

# Copy password to clipboard (macOS/Linux)
if command -v pbcopy &> /dev/null; then
  echo "$TOKEN_PASSWORD" | pbcopy
  echo "Password copied to clipboard (macOS)"
  echo ""
elif command -v xclip &> /dev/null; then
  echo "$TOKEN_PASSWORD" | xclip -selection clipboard
  echo "Password copied to clipboard (Linux)"
  echo ""
fi

cat > /tmp/customer-acr-email.txt << EOF
Subject: ACR Pull-Only Credentials for JIT Setup
ACR Server:  cdxjitacr111.azurecr.io
Username:    $TOKEN_USERNAME
Password:    $TOKEN_PASSWORD
Expires:     $TOKEN_EXPIRY
These credentials:
Allow PULL only (no push access)
Expire automatically in $TOKEN_DAYS days
Are scoped to JIT images only
EOF

cat /tmp/customer-acr-email.txt
echo ""