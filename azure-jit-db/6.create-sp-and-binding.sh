#!/usr/bin/env bash
# 6.create-sp-and-binding.sh - FIXED VERSION
# Handles cross-subscription databases
set -o errexit
set -o nounset
set -o pipefail

prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    while true; do
        read -p "$prompt (y/n) [$default_value]: " yn
        yn=${yn:-$default_value}
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Service Principal & AAD Database Binding"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Load JIT infrastructure config
if [ ! -f ~/jit-infra.env ]; then
  echo "[ERROR] ~/jit-infra.env not found. Run 2.setup-infra.sh first."
  exit 1
fi

source ~/jit-infra.env

# Get current subscription
CURRENT_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo ""
echo "JIT Infrastructure:"
echo "  Resource Group:     $RESOURCE_GROUP"
echo "  Managed Identity:   $IDENTITY_NAME"
echo "  Identity Client ID: $IDENTITY_CLIENT_ID"
echo "  Subscription:       $CURRENT_SUBSCRIPTION_ID"

# ── Step 1: Select Database Type ──────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Database Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Select database type:"
echo "  1) Azure Database for PostgreSQL Flexible Server"
echo "  2) Azure Database for MySQL Flexible Server"
echo "  3) Azure SQL Database"
read -p "Choice [1]: " DB_TYPE_CHOICE
DB_TYPE_CHOICE=${DB_TYPE_CHOICE:-1}

case $DB_TYPE_CHOICE in
  1)
    DB_TYPE="postgresql"
    DB_TYPE_NAME="PostgreSQL Flexible Server"
    AAD_SCOPE="https://ossrdbms-aad.database.windows.net/.default"
    ;;
  2)
    DB_TYPE="mysql"
    DB_TYPE_NAME="MySQL Flexible Server"
    AAD_SCOPE="https://ossrdbms-aad.database.windows.net/.default"
    ;;
  3)
    DB_TYPE="mssql"
    DB_TYPE_NAME="Azure SQL Database"
    AAD_SCOPE="https://database.windows.net/.default"
    ;;
  *)
    echo "[ERROR] Invalid choice"
    exit 1
    ;;
esac

echo "Selected: $DB_TYPE_NAME"

# ── Step 2: Database Server Details ────────────────────────
echo ""
read -p "Database server name: " DB_SERVER_NAME
read -p "Database resource group: " DB_RESOURCE_GROUP
read -p "Database subscription ID (if different) [$CURRENT_SUBSCRIPTION_ID]: " DB_SUBSCRIPTION_ID
DB_SUBSCRIPTION_ID=${DB_SUBSCRIPTION_ID:-$CURRENT_SUBSCRIPTION_ID}

# Check if cross-subscription
CROSS_SUBSCRIPTION=false
if [ "$DB_SUBSCRIPTION_ID" != "$CURRENT_SUBSCRIPTION_ID" ]; then
  CROSS_SUBSCRIPTION=true
  echo ""
  echo "[INFO] Cross-subscription database detected"
  echo "   Database subscription: $DB_SUBSCRIPTION_ID"
  echo "   JIT subscription:      $CURRENT_SUBSCRIPTION_ID"
fi

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)

# Get managed identity details
IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query principalId -o tsv)

echo ""
echo "Checking database server..."

# Build resource ID based on type
case $DB_TYPE in
  postgresql)
    DB_RESOURCE_ID="/subscriptions/${DB_SUBSCRIPTION_ID}/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${DB_SERVER_NAME}"
    ;;
  mysql)
    DB_RESOURCE_ID="/subscriptions/${DB_SUBSCRIPTION_ID}/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.DBforMySQL/flexibleServers/${DB_SERVER_NAME}"
    ;;
  mssql)
    DB_RESOURCE_ID="/subscriptions/${DB_SUBSCRIPTION_ID}/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.Sql/servers/${DB_SERVER_NAME}"
    ;;
esac

# Verify database exists (switch subscription if needed)
if [ "$CROSS_SUBSCRIPTION" = true ]; then
  echo "  Switching to database subscription to verify..."
  az account set --subscription $DB_SUBSCRIPTION_ID
fi

DB_EXISTS=$(az resource show --ids $DB_RESOURCE_ID --query id -o tsv 2>/dev/null || echo "")

if [ -z "$DB_EXISTS" ]; then
  echo "[ERROR] Database server not found: $DB_SERVER_NAME"
  if [ "$CROSS_SUBSCRIPTION" = true ]; then
    az account set --subscription $CURRENT_SUBSCRIPTION_ID
  fi
  exit 1
fi

echo "[OK] Database server found"

# ── Step 3: Check AAD Authentication Status ────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking AAD Authentication Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

AAD_ENABLED=false

case $DB_TYPE in
  postgresql)
    AUTH_CONFIG=$(az postgres flexible-server show \
      --resource-group $DB_RESOURCE_GROUP \
      --name $DB_SERVER_NAME \
      --query "authConfig.activeDirectoryAuth" -o tsv 2>/dev/null || echo "")
    
    if [ "$AUTH_CONFIG" = "Enabled" ]; then
      AAD_ENABLED=true
      echo "[OK] Azure AD authentication is ENABLED"
    else
      echo "  [WARNING] Azure AD authentication is DISABLED"
    fi
    ;;
    
  mysql)
    # MySQL doesn't have a simple query for AAD status
    # Check if AAD admin is set
    AAD_ADMIN=$(az mysql flexible-server ad-admin list \
      --resource-group $DB_RESOURCE_GROUP \
      --server-name $DB_SERVER_NAME \
      --query "[0].login" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$AAD_ADMIN" ]; then
      AAD_ENABLED=true
      echo "[OK] Azure AD authentication is ENABLED (admin: $AAD_ADMIN)"
    else
      echo "  [WARNING] Azure AD authentication is DISABLED (no AAD admin set)"
    fi
    ;;
    
  mssql)
    AAD_ADMIN=$(az sql server ad-admin list \
      --resource-group $DB_RESOURCE_GROUP \
      --server-name $DB_SERVER_NAME \
      --query "[0].login" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$AAD_ADMIN" ]; then
      AAD_ENABLED=true
      echo "[OK] Azure AD authentication is ENABLED (admin: $AAD_ADMIN)"
    else
      echo "  [WARNING] Azure AD authentication is DISABLED (no AAD admin set)"
    fi
    ;;
esac

# ── Step 4: Enable AAD if Needed ────────────────────────────
if [ "$AAD_ENABLED" = false ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[WARNING]  Azure AD Authentication Required"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Azure AD authentication must be enabled on the database server."
  echo ""
  
  case $DB_TYPE in
    postgresql)
      echo "This operation will:"
      echo "  1. Enable Azure AD authentication"
      echo "  2. Keep password authentication enabled (dual mode)"
      echo "  3. Cause a brief connection disruption (~30 seconds)"
      ;;
    mysql|mssql)
      echo "This operation will:"
      echo "  1. Set an Azure AD administrator"
      echo "  2. Enable Azure AD authentication"
      echo "  3. Minimal disruption to existing connections"
      ;;
  esac
  
  echo ""
  if ! prompt_yes_no "Enable Azure AD authentication now?" "y"; then
    echo "Setup cannot continue without AAD authentication."
    if [ "$CROSS_SUBSCRIPTION" = true ]; then
      az account set --subscription $CURRENT_SUBSCRIPTION_ID
    fi
    exit 1
  fi
  
  echo ""
  echo "Enabling Azure AD authentication..."
  
  case $DB_TYPE in
    postgresql)
      # Get current user as AAD admin
      CURRENT_USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
      CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
      
      # Step 1: Enable Active Directory authentication
      echo "  Enabling Active Directory authentication..."
      az postgres flexible-server update \
        --resource-group $DB_RESOURCE_GROUP \
        --name $DB_SERVER_NAME \
        --active-directory-auth Enabled \
        --password-auth Enabled \
        --output none
      
      # Step 2: Create AD admin
      echo "  Setting AD admin: $CURRENT_USER_EMAIL"
      az postgres flexible-server ad-admin create \
        --resource-group $DB_RESOURCE_GROUP \
        --server-name $DB_SERVER_NAME \
        --object-id $CURRENT_USER_OID \
        --principal-name "$CURRENT_USER_EMAIL" \
        --principal-type User \
        --output none
      
      echo "[OK] Active Directory enabled with admin: $CURRENT_USER_EMAIL"
      ;;
    
    mysql)
      CURRENT_USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
      CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
      
      echo "  Setting Azure AD admin: $CURRENT_USER_EMAIL"
      
      # Try approach 1: Create AAD admin directly (works with newer Azure CLI)
      if az mysql flexible-server ad-admin create \
        --resource-group $DB_RESOURCE_GROUP \
        --server-name $DB_SERVER_NAME \
        --display-name "$CURRENT_USER_EMAIL" \
        --object-id $CURRENT_USER_OID \
        --output none 2>/dev/null; then
        
        echo "[OK] Azure AD admin set: $CURRENT_USER_EMAIL"
      else
        # Approach 1 failed, try enabling server identity first
        echo "  Enabling system-assigned identity on server..."
        
        if az mysql flexible-server update \
          --resource-group $DB_RESOURCE_GROUP \
          --name $DB_SERVER_NAME \
          --identity \
          --output none 2>/dev/null; then
          
          echo "  [OK] Identity enabled, retrying AAD admin creation..."
          sleep 5
          
          # Retry AAD admin creation
          az mysql flexible-server ad-admin create \
            --resource-group $DB_RESOURCE_GROUP \
            --server-name $DB_SERVER_NAME \
            --display-name "$CURRENT_USER_EMAIL" \
            --object-id $CURRENT_USER_OID \
            --output none
          
          echo "[OK] Azure AD admin set: $CURRENT_USER_EMAIL"
        else
          echo "[ERROR] Could not enable identity or create AAD admin"
          echo "Try manually:"
          echo "  az mysql flexible-server update --name $DB_SERVER_NAME --resource-group $DB_RESOURCE_GROUP --identity"
          echo "  az mysql flexible-server ad-admin create --server-name $DB_SERVER_NAME --display-name \"$CURRENT_USER_EMAIL\" --object-id $CURRENT_USER_OID"
        fi
      fi
      ;;
      
    mssql)
      CURRENT_USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
      CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
      
      echo "  Setting AAD admin: $CURRENT_USER_EMAIL"
      az sql server ad-admin create \
        --resource-group $DB_RESOURCE_GROUP \
        --server-name $DB_SERVER_NAME \
        --display-name "$CURRENT_USER_EMAIL" \
        --object-id $CURRENT_USER_OID \
        --output none
      
      echo "[OK] Azure AD admin set: $CURRENT_USER_EMAIL"
      ;;
  esac
fi

# Switch back to JIT subscription if cross-subscription
if [ "$CROSS_SUBSCRIPTION" = true ]; then
  echo ""
  echo "Switching back to JIT subscription..."
  az account set --subscription $CURRENT_SUBSCRIPTION_ID
  echo "[OK] Back to JIT subscription"
fi

# ── Step 5: Create Service Principals ──────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Create Service Principals for Database Users"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Enter Service Principal names (database users) to create."
echo "Examples: jit-readonly, jit-writer, jit-admin"
echo "Enter one per line. Press Enter on empty line when done."
echo ""

SP_NAMES=()
while true; do
  read -p "SP name (or press Enter to finish): " SP_NAME
  if [ -z "$SP_NAME" ]; then
    break
  fi
  SP_NAMES+=("$SP_NAME")
done

if [ ${#SP_NAMES[@]} -eq 0 ]; then
  echo "No service principals to create. Exiting."
  exit 0
fi

echo ""
echo "Will create ${#SP_NAMES[@]} service principal(s):"
for name in "${SP_NAMES[@]}"; do
  echo "  - $name"
done

echo ""
if ! prompt_yes_no "Continue?" "y"; then
  exit 0
fi

# Store SP credentials for Key Vault
declare -A SP_CLIENT_IDS
declare -A SP_SECRETS
declare -A SP_OBJECT_IDS

echo ""
echo "Creating service principals..."

for SP_NAME in "${SP_NAMES[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Creating SP: $SP_NAME"
  
  # Create SP
  SP_OUTPUT=$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --skip-assignment \
    --output json)
  
  SP_CLIENT_ID=$(echo $SP_OUTPUT | jq -r '.appId')
  SP_SECRET=$(echo $SP_OUTPUT | jq -r '.password')
  
  # Get object ID
  SP_OBJECT_ID=$(az ad sp show --id $SP_CLIENT_ID --query id -o tsv)
  
  # Store
  SP_CLIENT_IDS[$SP_NAME]=$SP_CLIENT_ID
  SP_SECRETS[$SP_NAME]=$SP_SECRET
  SP_OBJECT_IDS[$SP_NAME]=$SP_OBJECT_ID
  
  echo "[OK] Created SP: $SP_NAME"
  echo "   App ID:    $SP_CLIENT_ID"
  echo "   Object ID: $SP_OBJECT_ID"
  
  # Wait for propagation
  sleep 5
  
  # Create federated credential (ACI managed identity → SP)
  FED_CRED_NAME="aci-${IDENTITY_NAME}-to-${SP_NAME}"
  
  echo "   Creating federated credential: $FED_CRED_NAME"
  
  az ad app federated-credential create \
    --id $SP_CLIENT_ID \
    --parameters "{
      \"name\": \"${FED_CRED_NAME}\",
      \"issuer\": \"https://login.microsoftonline.com/${TENANT_ID}/v2.0\",
      \"subject\": \"${IDENTITY_PRINCIPAL_ID}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" \
    --output none 2>/dev/null || echo "   [INFO] (federated credential may already exist)"
  
  echo "[OK] Federated credential configured"
done

# ── Step 6: Database User Creation Commands ────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Database User Setup Required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "[WARNING]  MANUAL STEP: Create database users and grant permissions"
echo ""
echo "Connect to your database as an Entra ID admin and run the following SQL:"
echo ""

# Get DB FQDN
case $DB_TYPE in
  postgresql)
    DB_FQDN="${DB_SERVER_NAME}.postgres.database.azure.com"
    ;;
  mysql)
    DB_FQDN="${DB_SERVER_NAME}.mysql.database.azure.com"
    ;;
  mssql)
    DB_FQDN="${DB_SERVER_NAME}.database.windows.net"
    ;;
esac

case $DB_TYPE in
  postgresql)
    echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "# PostgreSQL Setup"
    echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "# 1. Connect as Entra ID admin:"
    echo "export PGPASSWORD=\$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)"
    if [ "$CROSS_SUBSCRIPTION" = true ]; then
      echo "# Note: If database is in different subscription, switch first:"
      echo "# az account set --subscription $DB_SUBSCRIPTION_ID"
    fi
    echo "psql \"host=${DB_FQDN} port=5432 dbname=postgres user=$(az ad signed-in-user show --query userPrincipalName -o tsv) sslmode=require\""
    echo ""
    echo "# 2. Create users and grant permissions:"
    echo ""
    for SP_NAME in "${SP_NAMES[@]}"; do
      OBJECT_ID="${SP_OBJECT_IDS[$SP_NAME]}"
      echo "-- Create user: $SP_NAME"
      echo "SELECT * FROM pgaadauth_create_principal_with_oid('${SP_NAME}', '${OBJECT_ID}', 'service', false, false);"
      echo ""
      echo "-- Grant permissions (example for testdb):"
      echo "GRANT CONNECT ON DATABASE testdb TO \"${SP_NAME}\";"
      echo "\\c testdb"
      echo "GRANT USAGE ON SCHEMA public TO \"${SP_NAME}\";"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"${SP_NAME}\";"
      echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"${SP_NAME}\";"
      echo ""
      echo "-- Or for read-only access:"
      echo "-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"${SP_NAME}\";"
      echo ""
      echo "---"
      echo ""
    done
    ;;
    
  mysql)
    echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "# MySQL Setup"
    echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "# 1. Get access token:"
    if [ "$CROSS_SUBSCRIPTION" = true ]; then
      echo "# Note: If database is in different subscription, switch first:"
      echo "# az account set --subscription $DB_SUBSCRIPTION_ID"
    fi
    echo "TOKEN=\$(az account get-access-token --resource https://ossrdbms-aad.database.windows.net --query accessToken -o tsv)"
    echo ""
    echo "# 2. Connect as AAD admin:"
    echo "mysql -h ${DB_FQDN} -u $(az ad signed-in-user show --query userPrincipalName -o tsv) --enable-cleartext-plugin --password=\"\$TOKEN\""
    echo ""
    echo "# 3. Create users and grant permissions:"
    echo ""
    for SP_NAME in "${SP_NAMES[@]}"; do
      echo "-- Create user: $SP_NAME"
      echo "CREATE AADUSER '${SP_NAME}';"
      echo ""
      echo "-- Grant permissions (adjust database name and privileges):"
      echo "GRANT SELECT ON testdb.* TO '${SP_NAME}'@'%';"
      echo "-- For write access:"
      echo "-- GRANT INSERT, UPDATE, DELETE ON testdb.* TO '${SP_NAME}'@'%';"
      echo "FLUSH PRIVILEGES;"
      echo ""
      echo "---"
      echo ""
    done
    ;;
    
  mssql)
    echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "# Azure SQL Database Setup"
    echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "# 1. Connect as AAD admin:"
    if [ "$CROSS_SUBSCRIPTION" = true ]; then
      echo "# Note: If database is in different subscription, switch first:"
      echo "# az account set --subscription $DB_SUBSCRIPTION_ID"
    fi
    echo "sqlcmd -S ${DB_FQDN} -d <your-db> -G -U $(az ad signed-in-user show --query userPrincipalName -o tsv)"
    echo ""
    echo "# 2. Create users and grant permissions:"
    echo ""
    for SP_NAME in "${SP_NAMES[@]}"; do
      echo "-- Create user: $SP_NAME"
      echo "CREATE USER [${SP_NAME}] FROM EXTERNAL PROVIDER;"
      echo ""
      echo "-- Grant permissions:"
      echo "ALTER ROLE db_datareader ADD MEMBER [${SP_NAME}];"
      echo "-- For write access:"
      echo "-- ALTER ROLE db_datawriter ADD MEMBER [${SP_NAME}];"
      echo ""
      echo "---"
      echo ""
    done
    ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Service Principal Details"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for SP_NAME in "${SP_NAMES[@]}"; do
  CLIENT_ID="${SP_CLIENT_IDS[$SP_NAME]}"
  OBJECT_ID="${SP_OBJECT_IDS[$SP_NAME]}"
  echo "Service Principal: $SP_NAME"
  echo "  App ID (Client ID): $CLIENT_ID"
  echo "  Object ID:          $OBJECT_ID"
  echo "  Tenant ID:          $TENANT_ID"
  echo "  Scope:              $AAD_SCOPE"
  echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[OK] Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Created: ${#SP_NAMES[@]} service principal(s)"
echo "Federated Credentials: Configured for ACI managed identity"
echo "Managed Identity: $IDENTITY_NAME ($IDENTITY_CLIENT_ID)"
echo ""
if [ "$CROSS_SUBSCRIPTION" = true ]; then
  echo "[WARNING]  Cross-subscription setup:"
  echo "   JIT subscription:      $CURRENT_SUBSCRIPTION_ID"
  echo "   Database subscription: $DB_SUBSCRIPTION_ID"
  echo ""
  echo "   When connecting to database, remember to switch subscriptions:"
  echo "   az account set --subscription $DB_SUBSCRIPTION_ID"
  echo ""
fi
echo "Next: Run the SQL commands above to create database users"
echo ""

# Save configuration
cat > ~/sp-db-binding-${DB_SERVER_NAME}.env <<EOF
# Service Principal Database Binding Configuration
DB_TYPE=$DB_TYPE
DB_SERVER_NAME=$DB_SERVER_NAME
DB_RESOURCE_GROUP=$DB_RESOURCE_GROUP
DB_SUBSCRIPTION_ID=$DB_SUBSCRIPTION_ID
DB_FQDN=$DB_FQDN
CROSS_SUBSCRIPTION=$CROSS_SUBSCRIPTION
TENANT_ID=$TENANT_ID
AAD_SCOPE=$AAD_SCOPE
MANAGED_IDENTITY_NAME=$IDENTITY_NAME
MANAGED_IDENTITY_CLIENT_ID=$IDENTITY_CLIENT_ID
MANAGED_IDENTITY_PRINCIPAL_ID=$IDENTITY_PRINCIPAL_ID
CREATED_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Service Principals
SP_COUNT=${#SP_NAMES[@]}
EOF

# Add SP details to file
i=1
for SP_NAME in "${SP_NAMES[@]}"; do
  cat >> ~/sp-db-binding-${DB_SERVER_NAME}.env <<EOF
SP${i}_NAME=$SP_NAME
SP${i}_CLIENT_ID=${SP_CLIENT_IDS[$SP_NAME]}
SP${i}_OBJECT_ID=${SP_OBJECT_IDS[$SP_NAME]}
EOF
  ((i++))
done

echo "[SAVED] Configuration saved to: ~/sp-db-binding-${DB_SERVER_NAME}.env"
echo ""