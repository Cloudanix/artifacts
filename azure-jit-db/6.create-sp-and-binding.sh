#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================
# Create Service Principal & Database Binding (Script 6)
# Proven MySQL workflow from manual testing
# ============================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Service Principal & AAD Database Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Load JIT infrastructure config
if [ ! -f ~/jit-infra.env ]; then
  echo "ERROR JIT infrastructure config not found"
  echo "Please run ./2.setup-infra.sh first"
  exit 1
fi

source ~/jit-infra.env

# Get tenant and identity info
TENANT_ID=$(az account show --query tenantId -o tsv)
CURRENT_SUB=$(az account show --query id -o tsv)

ACI_IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query clientId -o tsv)

ACI_IDENTITY_OBJECT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query principalId -o tsv)

IDENTITY_RESOURCE_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query id -o tsv)

echo "JIT Infrastructure:"
echo "  Resource Group:   $RESOURCE_GROUP"
echo "  Managed Identity: $IDENTITY_NAME"
echo "  Client ID:        $ACI_IDENTITY_CLIENT_ID"
echo "  Principal ID:     $ACI_IDENTITY_OBJECT_ID"
echo "  Tenant ID:        $TENANT_ID"
echo "  Subscription:     $CURRENT_SUB"
echo ""

# ── Database Type Selection ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Database Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Select database type:"
echo "  1) PostgreSQL Flexible Server"
echo "  2) MySQL Flexible Server"
echo "  3) Azure SQL Database"
read -p "Choice [1]: " DB_TYPE
DB_TYPE=${DB_TYPE:-1}

case $DB_TYPE in
  1)
    DB_ENGINE="postgresql"
    AAD_SCOPE="https://ossrdbms-aad.database.windows.net/.default"
    ;;
  2)
    DB_ENGINE="mysql"
    AAD_SCOPE="https://ossrdbms-aad.database.windows.net/.default"
    ;;
  3)
    DB_ENGINE="mssql"
    AAD_SCOPE="https://database.windows.net/.default"
    ;;
  *)
    echo "ERROR Invalid choice"
    exit 1
    ;;
esac

echo ""
read -p "Database server name: " DB_SERVER
read -p "Resource group: " DB_RG
read -p "Subscription (if different) [$CURRENT_SUB]: " DB_SUB
DB_SUB=${DB_SUB:-$CURRENT_SUB}

CROSS_SUB=false
if [ "$DB_SUB" != "$CURRENT_SUB" ]; then
  CROSS_SUB=true
  echo ""
  echo "LOCATION Cross-subscription setup detected"
  echo "  DB subscription:  $DB_SUB"
  echo "  JIT subscription: $CURRENT_SUB"
fi

# ── Service Principal Names ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Service Principal Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Enter service principal names (one per line, empty to finish):"

SP_NAMES=()
while true; do
  read -p "SP name: " SP_NAME
  [ -z "$SP_NAME" ] && break
  SP_NAMES+=("$SP_NAME")
done

if [ ${#SP_NAMES[@]} -eq 0 ]; then
  echo "ERROR No service principals to create"
  exit 1
fi

echo ""
echo "Will create ${#SP_NAMES[@]} service principal(s):"
for SP_NAME in "${SP_NAMES[@]}"; do
  echo "  - $SP_NAME"
done

# ── Create Service Principals ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating Service Principals"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

declare -A SP_APP_IDS
declare -A SP_OBJECT_IDS

for SP_NAME in "${SP_NAMES[@]}"; do
  echo ""
  echo "Creating: $SP_NAME"
  
  # Create SP
  SP_OUTPUT=$(az ad sp create-for-rbac --name "$SP_NAME" --skip-assignment 2>/dev/null)
  SP_APP_ID=$(echo $SP_OUTPUT | jq -r '.appId')
  SP_OBJECT_ID=$(az ad sp show --id $SP_APP_ID --query id -o tsv)
  
  SP_APP_IDS[$SP_NAME]=$SP_APP_ID
  SP_OBJECT_IDS[$SP_NAME]=$SP_OBJECT_ID
  
  echo "  App ID:    $SP_APP_ID"
  echo "  Object ID: $SP_OBJECT_ID"
  
  # Wait for AD propagation
  sleep 2
  
  # Create federated credential with proper JSON escaping
  echo "  Creating federated credential..."
  
  az ad app federated-credential create \
    --id $SP_APP_ID \
    --parameters "{
      \"name\": \"aci-federated-${SP_NAME}\",
      \"issuer\": \"https://login.microsoftonline.com/${TENANT_ID}/v2.0\",
      \"subject\": \"${ACI_IDENTITY_OBJECT_ID}\",
      \"audiences\": [\"api://AzureADTokenExchange\"],
      \"description\": \"Federated credential for ACI to ${DB_ENGINE}\"
    }" 2>/dev/null || echo "  (credential may already exist)"
  
  echo "  OK Service principal created"
done

# ── Configure Database Server ──
if [ "$DB_ENGINE" = "mysql" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Configuring MySQL Server"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Switch to DB subscription if cross-sub
  if [ "$CROSS_SUB" = true ]; then
    echo ""
    echo "Switching to database subscription..."
    az account set --subscription $DB_SUB
  fi
  
  echo ""
  echo "Step 1: Assigning managed identity to MySQL server..."
  
  az mysql flexible-server identity assign \
    --resource-group $DB_RG \
    --server-name $DB_SERVER \
    --identity "$IDENTITY_RESOURCE_ID" \
    --output none
  
  echo "OK Identity assigned"
  
  echo ""
  echo "Step 2: Setting Entra ID admin..."
  
  USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
  USER_OID=$(az ad signed-in-user show --query id -o tsv)
  
  az mysql flexible-server ad-admin create \
    --resource-group $DB_RG \
    --server-name $DB_SERVER \
    --object-id $USER_OID \
    --display-name $USER_EMAIL \
    --identity "$IDENTITY_RESOURCE_ID" \
    --output none
  
  echo "OK Entra ID admin configured"
  
  # Switch back if cross-sub
  if [ "$CROSS_SUB" = true ]; then
    echo ""
    echo "Switching back to JIT subscription..."
    az account set --subscription $CURRENT_SUB
  fi
  
elif [ "$DB_ENGINE" = "postgresql" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "PostgreSQL Configuration"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Switch to DB subscription if cross-sub
  if [ "$CROSS_SUB" = true ]; then
    az account set --subscription $DB_SUB
  fi
  
  echo ""
  echo "Checking Entra ID status..."
  
  PG_AAD_ADMIN=$(az postgres flexible-server microsoft-entra-admin list \
    --resource-group $DB_RG \
    --server-name $DB_SERVER \
    --query "[0].principalName" -o tsv 2>/dev/null || echo "")
  
  if [ -z "$PG_AAD_ADMIN" ]; then
    echo "WARNING  Entra ID not enabled"
    echo ""
    echo "Enabling Entra ID authentication..."
    
    # Enable Entra auth
    az postgres flexible-server update \
      --resource-group $DB_RG \
      --name $DB_SERVER \
      --microsoft-entra-auth Enabled \
      --password-auth Enabled \
      --output none
    
    # Set admin
    USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
    USER_OID=$(az ad signed-in-user show --query id -o tsv)
    
    az postgres flexible-server microsoft-entra-admin create \
      --resource-group $DB_RG \
      --server-name $DB_SERVER \
      --object-id $USER_OID \
      --principal-name $USER_EMAIL \
      --principal-type User \
      --output none
    
    echo "OK Entra ID enabled"
  else
    echo "OK Entra ID already enabled (admin: $PG_AAD_ADMIN)"
  fi
  
  # Switch back if cross-sub
  if [ "$CROSS_SUB" = true ]; then
    az account set --subscription $CURRENT_SUB
  fi
  
elif [ "$DB_ENGINE" = "mssql" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Azure SQL Configuration"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Switch to DB subscription if cross-sub
  if [ "$CROSS_SUB" = true ]; then
    az account set --subscription $DB_SUB
  fi
  
  echo ""
  echo "Checking Entra ID status..."
  
  SQL_AAD_ADMIN=$(az sql server ad-admin list \
    --resource-group $DB_RG \
    --server-name $DB_SERVER \
    --query "[0].login" -o tsv 2>/dev/null || echo "")
  
  if [ -z "$SQL_AAD_ADMIN" ]; then
    echo "WARNING  Entra ID not enabled"
    echo ""
    echo "Setting Entra ID admin..."
    
    USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
    USER_OID=$(az ad signed-in-user show --query id -o tsv)
    
    az sql server ad-admin create \
      --resource-group $DB_RG \
      --server-name $DB_SERVER \
      --display-name $USER_EMAIL \
      --object-id $USER_OID \
      --output none
    
    echo "OK Entra ID admin set"
  else
    echo "OK Entra ID already enabled (admin: $SQL_AAD_ADMIN)"
  fi
  
  # Switch back if cross-sub
  if [ "$CROSS_SUB" = true ]; then
    az account set --subscription $CURRENT_SUB
  fi
fi

# ── Save Configuration ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Saving Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CONFIG_FILE=~/sp-config-${DB_SERVER}.env

cat > $CONFIG_FILE <<EOF
# Service Principal Configuration
# Database: $DB_SERVER
# Type: $DB_ENGINE
# Generated: $(date)

DB_ENGINE=$DB_ENGINE
DB_SERVER=$DB_SERVER
DB_RG=$DB_RG
DB_SUB=$DB_SUB
TENANT_ID=$TENANT_ID
AAD_SCOPE=$AAD_SCOPE
IDENTITY_RESOURCE_ID=$IDENTITY_RESOURCE_ID
ACI_IDENTITY_OBJECT_ID=$ACI_IDENTITY_OBJECT_ID

# Service Principals
SP_COUNT=${#SP_NAMES[@]}
EOF

i=1
for SP_NAME in "${SP_NAMES[@]}"; do
  cat >> $CONFIG_FILE <<EOF
SP${i}_NAME=$SP_NAME
SP${i}_APP_ID=${SP_APP_IDS[$SP_NAME]}
SP${i}_OBJECT_ID=${SP_OBJECT_IDS[$SP_NAME]}
EOF
  ((i++))
done

echo "OK Configuration saved: $CONFIG_FILE"

# ── Generate Instructions ──
INSTRUCTIONS_FILE=~/db-user-creation-${DB_SERVER}.txt

cat > $INSTRUCTIONS_FILE <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Database User Creation Instructions
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Server: $DB_SERVER
Type:   $DB_ENGINE
Date:   $(date)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 1: Get Entra ID Token (Local Machine)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Run on your local machine:

TOKEN=\$(az account get-access-token \\
  --resource $AAD_SCOPE \\
  --query accessToken -o tsv)

echo "Token length: \${#TOKEN}"
echo "Copy this token:"
echo \$TOKEN

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 2: Connect to Database (ACI Container)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Exec into ACI container
az container exec \\
  --resource-group $RESOURCE_GROUP \\
  --name dam-server \\
  --exec-command "/bin/bash"

# Inside container, set the token
TOKEN="<paste-token-from-step-1>"

EOF

if [ "$DB_ENGINE" = "mysql" ]; then
  USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
  
  cat >> $INSTRUCTIONS_FILE <<EOF
# Connect to MySQL
mysql -h ${DB_SERVER}.mysql.database.azure.com \\
  --user=$USER_EMAIL \\
  --password="\$TOKEN"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 3: Create Database Users (MySQL Prompt)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

In the MySQL prompt, run:

SET aad_auth_validate_oids_in_tenant = OFF;

EOF

  for SP_NAME in "${SP_NAMES[@]}"; do
    OID="${SP_OBJECT_IDS[$SP_NAME]}"
    cat >> $INSTRUCTIONS_FILE <<EOF
-- Create user: $SP_NAME
CREATE AADUSER '$SP_NAME' IDENTIFIED BY '$OID';
GRANT SELECT ON *.* TO '$SP_NAME'@'%';
FLUSH PRIVILEGES;

EOF
  done

  cat >> $INSTRUCTIONS_FILE <<EOF
-- Verify users
SELECT user, host FROM mysql.user WHERE user IN ($(printf "'%s'," "${SP_NAMES[@]}" | sed 's/,$//'));

exit;

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 4: Test Token Exchange (ACI Container)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Set variables (pick one SP to test)
SP_NAME="${SP_NAMES[0]}"
SP_APP_ID="${SP_APP_IDS[${SP_NAMES[0]}]}"
SP_OBJECT_ID="${SP_OBJECT_IDS[${SP_NAMES[0]}]}"
TENANT_ID="$TENANT_ID"

# Get ACI token
ACI_TOKEN=\$(curl -s "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://AzureADTokenExchange" \\
  -H "Metadata: true" \\
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "ACI Token length: \${#ACI_TOKEN}"

# Exchange for MySQL token
MYSQL_TOKEN=\$(curl -s -X POST \\
  "https://login.microsoftonline.com/\${TENANT_ID}/oauth2/v2.0/token" \\
  -H "Content-Type: application/x-www-form-urlencoded" \\
  -d "grant_type=client_credentials" \\
  -d "client_id=\${SP_APP_ID}" \\
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \\
  -d "client_assertion=\${ACI_TOKEN}" \\
  -d "scope=$AAD_SCOPE" \\
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "MySQL token length: \${#MYSQL_TOKEN}"

# Test connection
mysql -h ${DB_SERVER}.mysql.database.azure.com \\
  --user=\${SP_NAME} \\
  --password="\$MYSQL_TOKEN" \\
  -e "SELECT USER(), DATABASE(); SHOW DATABASES;"

EOF

elif [ "$DB_ENGINE" = "postgresql" ]; then
  USER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv)
  
  cat >> $INSTRUCTIONS_FILE <<EOF
# Connect to PostgreSQL
PGPASSWORD=\$TOKEN psql \\
  "host=${DB_SERVER}.postgres.database.azure.com \\
   port=5432 \\
   dbname=postgres \\
   user=$USER_EMAIL \\
   sslmode=require"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 3: Create Database Users (PostgreSQL)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

In the psql prompt, run:

EOF

  for SP_NAME in "${SP_NAMES[@]}"; do
    OID="${SP_OBJECT_IDS[$SP_NAME]}"
    cat >> $INSTRUCTIONS_FILE <<EOF
-- Create user: $SP_NAME
SELECT * FROM pgaadauth_create_principal_with_oid('$SP_NAME', '$OID', 'service', false, false);
GRANT CONNECT ON DATABASE testdb TO "$SP_NAME";
\\c testdb
GRANT USAGE ON SCHEMA public TO "$SP_NAME";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$SP_NAME";

EOF
  done

  cat >> $INSTRUCTIONS_FILE <<EOF
\\q

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 4: Test Token Exchange (ACI Container)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Set variables (pick one SP to test)
SP_NAME="${SP_NAMES[0]}"
SP_APP_ID="${SP_APP_IDS[${SP_NAMES[0]}]}"
TENANT_ID="$TENANT_ID"

# Get ACI token
ACI_TOKEN=\$(curl -s "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://AzureADTokenExchange" \\
  -H "Metadata: true" \\
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Exchange for PostgreSQL token
export PGPASSWORD=\$(curl -s -X POST \\
  "https://login.microsoftonline.com/\${TENANT_ID}/oauth2/v2.0/token" \\
  -H "Content-Type: application/x-www-form-urlencoded" \\
  -d "grant_type=client_credentials" \\
  -d "client_id=\${SP_APP_ID}" \\
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \\
  -d "client_assertion=\${ACI_TOKEN}" \\
  -d "scope=$AAD_SCOPE" \\
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Test connection
psql "host=${DB_SERVER}.postgres.database.azure.com port=5432 dbname=testdb user=\${SP_NAME} sslmode=require" \\
  -c "SELECT current_user, current_database();"

EOF

else
  cat >> $INSTRUCTIONS_FILE <<EOF
NOTE: For SQL Server, database user creation requires Python/pyodbc.
See MSSQL-NORTHWIND-GUIDE.md for detailed instructions.

EOF
fi

cat >> $INSTRUCTIONS_FILE <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Service Principal Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

for SP_NAME in "${SP_NAMES[@]}"; do
  cat >> $INSTRUCTIONS_FILE <<EOF
$SP_NAME:
  App ID:    ${SP_APP_IDS[$SP_NAME]}
  Object ID: ${SP_OBJECT_IDS[$SP_NAME]}

EOF
done

echo "OK Instructions saved: $INSTRUCTIONS_FILE"

# ── Summary ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "OK Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Created ${#SP_NAMES[@]} service principal(s):"
for SP_NAME in "${SP_NAMES[@]}"; do
  echo "  OK $SP_NAME"
  echo "     App ID: ${SP_APP_IDS[$SP_NAME]}"
done
echo ""
echo "Files created:"
echo "  FILE Configuration: $CONFIG_FILE"
echo "  FILE Instructions:  $INSTRUCTIONS_FILE"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Next Steps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Follow the instructions in:"
echo "  cat $INSTRUCTIONS_FILE"
echo ""
echo "Summary:"
echo "  1. Get Entra ID token (local machine)"
echo "  2. Connect to database (ACI container)"
echo "  3. Create database users (interactive SQL)"
echo "  4. Test token exchange (ACI container)"
echo ""