#!/usr/bin/env bash
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
  echo " ~/jit-infra.env not found. Run 2.setup-infra.sh first."
  exit 1
fi

source ~/jit-infra.env

echo ""
echo "JIT Infrastructure:"
echo "  Resource Group:     $RESOURCE_GROUP"
echo "  Managed Identity:   $IDENTITY_NAME"
echo "  Identity Client ID: $IDENTITY_CLIENT_ID"

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
    echo "Invalid choice"
    exit 1
    ;;
esac

echo "Selected: $DB_TYPE_NAME"

# ── Step 2: Database Server Details ────────────────────────
echo ""
read -p "Database server name: " DB_SERVER_NAME
read -p "Database resource group: " DB_RESOURCE_GROUP

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
    DB_RESOURCE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${DB_SERVER_NAME}"
    ;;
  mysql)
    DB_RESOURCE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.DBforMySQL/flexibleServers/${DB_SERVER_NAME}"
    ;;
  mssql)
    DB_RESOURCE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.Sql/servers/${DB_SERVER_NAME}"
    ;;
esac

# Verify database exists
DB_EXISTS=$(az resource show --ids $DB_RESOURCE_ID --query id -o tsv 2>/dev/null || echo "")
if [ -z "$DB_EXISTS" ]; then
  echo " Database server not found: $DB_SERVER_NAME"
  exit 1
fi

echo " Database server found"

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
      echo " Azure AD authentication is ENABLED"
    else
      echo "  Azure AD authentication is DISABLED"
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
      echo " Azure AD authentication is ENABLED (admin: $AAD_ADMIN)"
    else
      echo "  Azure AD authentication is DISABLED (no AAD admin set)"
    fi
    ;;
    
  mssql)
    AAD_ADMIN=$(az sql server ad-admin list \
      --resource-group $DB_RESOURCE_GROUP \
      --server-name $DB_SERVER_NAME \
      --query "[0].login" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$AAD_ADMIN" ]; then
      AAD_ENABLED=true
      echo " Azure AD authentication is ENABLED (admin: $AAD_ADMIN)"
    else
      echo "  Azure AD authentication is DISABLED (no AAD admin set)"
    fi
    ;;
esac

# ── Step 4: Enable AAD if Needed ────────────────────────────
if [ "$AAD_ENABLED" = false ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Azure AD Authentication Required"
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
    exit 1
  fi
  
  echo ""
  echo "Enabling Azure AD authentication..."
  
  case $DB_TYPE in
    postgresql)
      # Get current user as AAD admin
      CURRENT_USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
      CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
      
      # Step 1: Enable Entra ID authentication
      echo "  Enabling Microsoft Entra ID authentication..."
      az postgres flexible-server update \
        --resource-group $DB_RESOURCE_GROUP \
        --name $DB_SERVER_NAME \
        --microsoft-entra-auth Enabled \
        --password-auth Enabled \
        --output none
      
      # Step 2: Create Entra ID admin
      echo "  Setting Entra ID admin: $CURRENT_USER_EMAIL"
      az postgres flexible-server microsoft-entra-admin create \
        --resource-group $DB_RESOURCE_GROUP \
        --server-name $DB_SERVER_NAME \
        --display-name "$CURRENT_USER_EMAIL" \
        --object-id $CURRENT_USER_OID \
        --type User \
        --output none
      
      echo " Entra ID enabled with admin: $CURRENT_USER_EMAIL"
      ;;
    
    mysql)
      CURRENT_USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
      CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
      
      # Step 1: Enable Entra ID authentication
      echo "  Enabling Microsoft Entra ID authentication..."
      az mysql flexible-server update \
        --resource-group $DB_RESOURCE_GROUP \
        --name $DB_SERVER_NAME \
        --microsoft-entra-auth Enabled \
        --password-auth Enabled \
        --output none
      
      # Step 2: Create Entra ID admin
      echo "  Setting Entra ID admin: $CURRENT_USER_EMAIL"
      az mysql flexible-server microsoft-entra-admin create \
        --resource-group $DB_RESOURCE_GROUP \
        --server-name $DB_SERVER_NAME \
        --display-name "$CURRENT_USER_EMAIL" \
        --object-id $CURRENT_USER_OID \
        --type User \
        --output none
      
      echo " Entra ID enabled with admin: $CURRENT_USER_EMAIL"
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
      
      echo " Azure AD admin set: $CURRENT_USER_EMAIL"
      ;;
  esac
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
  
  echo " Created SP: $SP_NAME"
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
    --output none 2>/dev/null || echo "   (federated credential may already exist)"
  
  echo " Federated credential configured"
done

# ── Step 6: Database User Creation Commands ────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Database User Setup Required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "  MANUAL STEP: Create database users and grant permissions"
echo ""
echo "Connect to your database as an Entra ID admin and run the following SQL:"
echo ""

case $DB_TYPE in
  postgresql)
    echo "-- Connect as Entra ID admin:"
    echo "export PGPASSWORD=\$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)"
    echo "psql \"host=${DB_SERVER_NAME}.postgres.database.azure.com port=5432 dbname=postgres user=$(az ad signed-in-user show --query userPrincipalName -o tsv) sslmode=require password=\$PGPASSWORD\""
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
    echo "-- Connect as AAD admin"
    echo "-- mysql -h ${DB_SERVER_NAME}.mysql.database.azure.com -u <your-aad-admin> --enable-cleartext-plugin --password=\$(az account get-access-token --resource https://ossrdbms-aad.database.windows.net --query accessToken -o tsv)"
    echo ""
    for SP_NAME in "${SP_NAMES[@]}"; do
      echo "-- Create user: $SP_NAME"
      echo "CREATE AADUSER '${SP_NAME}';"
      echo ""
      echo "-- Grant permissions (adjust as needed):"
      echo "GRANT SELECT ON your_database.* TO '${SP_NAME}'@'%';"
      echo "-- For write access:"
      echo "-- GRANT INSERT, UPDATE, DELETE ON your_database.* TO '${SP_NAME}'@'%';"
      echo "FLUSH PRIVILEGES;"
      echo ""
      echo "---"
      echo ""
    done
    ;;
    
  mssql)
    echo "-- Connect as AAD admin"
    echo "-- sqlcmd -S ${DB_SERVER_NAME}.database.windows.net -d <your-db> -G -U <your-aad-admin>"
    echo ""
    for SP_NAME in "${SP_NAMES[@]}"; do
      echo "-- Create user: $SP_NAME"
      echo "CREATE USER [${SP_NAME}] FROM EXTERNAL PROVIDER;"
      echo ""
      echo "-- Grant permissions (adjust as needed):"
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

for SP_NAME in "${SP_NAMES[@]}"; do
  CLIENT_ID="${SP_CLIENT_IDS[$SP_NAME]}"
  echo "# For service principal: $SP_NAME"
  echo "---"
  echo ""
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Service Principals Created: ${#SP_NAMES[@]}"
for SP_NAME in "${SP_NAMES[@]}"; do
  CLIENT_ID="${SP_CLIENT_IDS[$SP_NAME]}"
  OBJECT_ID="${SP_OBJECT_IDS[$SP_NAME]}"
  echo "   $SP_NAME"
  echo "     App ID:    $CLIENT_ID"
  echo "     Object ID: $OBJECT_ID"
done
echo ""
echo "Federated Credentials: Configured for ACI managed identity"
echo "Managed Identity:      $IDENTITY_NAME ($IDENTITY_CLIENT_ID)"
echo ""
echo ""