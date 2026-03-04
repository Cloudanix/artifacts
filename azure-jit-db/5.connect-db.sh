#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  read -p "$prompt [$default_value]: " user_input
  echo "${user_input:-$default_value}"
}

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
echo "Connect Customer Database via Private Link"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Load JIT infrastructure config
if [ ! -f ~/jit-infra.env ]; then
  echo "
 ~/jit-infra.env not found. Run 03-setup-infrastructure.sh first."
  exit 1
fi

source ~/jit-infra.env

# Get current subscription ID
CURRENT_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo ""
echo "JIT Infrastructure:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  VNet:           $VNET_NAME"
echo "  Location:       $LOCATION"
echo "  Subscription:   $CURRENT_SUBSCRIPTION_ID"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Database Information"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Database type
echo ""
echo "Select database type:"
echo "  1) Azure SQL Database"
echo "  2) Azure Database for PostgreSQL Flexible Server"
echo "  3) Azure Database for MySQL Flexible Server"
read -p "Choice [2]: " DB_TYPE_CHOICE
DB_TYPE_CHOICE=${DB_TYPE_CHOICE:-2}

case $DB_TYPE_CHOICE in
  1)
    DB_TYPE="sql"
    DB_TYPE_NAME="Azure SQL Database"
    GROUP_ID="sqlServer"
    ;;
  2)
    DB_TYPE="postgresql"
    DB_TYPE_NAME="PostgreSQL Flexible Server"
    GROUP_ID="postgresqlServer"
    ;;
  3)
    DB_TYPE="mysql"
    DB_TYPE_NAME="MySQL Flexible Server"
    GROUP_ID="mysqlServer"
    ;;
  *)
    echo "
 Invalid choice"
    exit 1
    ;;
esac

echo "Selected: $DB_TYPE_NAME"

# Database details
echo ""
read -p "Database server name: " DB_SERVER_NAME
read -p "Database resource group: " DB_RESOURCE_GROUP
read -p "Database subscription ID (if different) [$CURRENT_SUBSCRIPTION_ID]: " DB_SUBSCRIPTION_ID
DB_SUBSCRIPTION_ID=${DB_SUBSCRIPTION_ID:-$CURRENT_SUBSCRIPTION_ID}

# Build database resource ID
case $DB_TYPE in
  sql)
    DB_RESOURCE_ID="/subscriptions/${DB_SUBSCRIPTION_ID}/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.Sql/servers/${DB_SERVER_NAME}"
    ;;
  postgresql)
    DB_RESOURCE_ID="/subscriptions/${DB_SUBSCRIPTION_ID}/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${DB_SERVER_NAME}"
    ;;
  mysql)
    DB_RESOURCE_ID="/subscriptions/${DB_SUBSCRIPTION_ID}/resourceGroups/${DB_RESOURCE_GROUP}/providers/Microsoft.DBforMySQL/flexibleServers/${DB_SERVER_NAME}"
    ;;
esac

echo ""
echo "Database Resource ID:"
echo "  $DB_RESOURCE_ID"

# Check if cross-subscription
CROSS_SUBSCRIPTION=false
if [ "$DB_SUBSCRIPTION_ID" != "$CURRENT_SUBSCRIPTION_ID" ]; then
  CROSS_SUBSCRIPTION=true
  echo ""
  echo " Cross-subscription private endpoint detected"
  echo "   Database subscription: $DB_SUBSCRIPTION_ID"
  echo "   JIT subscription:      $CURRENT_SUBSCRIPTION_ID"
fi

# Verify database exists and get location
echo ""
echo "Verifying database..."

# If cross-subscription, temporarily switch to DB subscription to verify
if [ "$CROSS_SUBSCRIPTION" = true ]; then
  az account set --subscription $DB_SUBSCRIPTION_ID
fi

DB_LOCATION=$(az resource show \
  --ids $DB_RESOURCE_ID \
  --query location -o tsv 2>/dev/null || echo "")

if [ -z "$DB_LOCATION" ]; then
  echo " Database not found or no access"
  if [ "$CROSS_SUBSCRIPTION" = true ]; then
    az account set --subscription $CURRENT_SUBSCRIPTION_ID
  fi
  exit 1
fi

echo "Database found in region: $DB_LOCATION"

if [ "$DB_LOCATION" != "$LOCATION" ]; then
  echo "    Database is in different region than JIT infrastructure"
  echo "     This is supported but may have higher latency"
fi

# Handle cross-subscription Microsoft.Network registration
if [ "$CROSS_SUBSCRIPTION" = true ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Cross-Subscription Setup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Checking Microsoft.Network provider in database subscription..."
  
  # Check if Microsoft.Network is registered in DB subscription
  NETWORK_STATUS=$(az provider show \
    --namespace Microsoft.Network \
    --subscription $DB_SUBSCRIPTION_ID \
    --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  
  echo "  Current status: $NETWORK_STATUS"
  
  if [ "$NETWORK_STATUS" != "Registered" ]; then
    echo ""
    echo "  Microsoft.Network provider is not registered in database subscription"
    echo "   This is required for cross-subscription private endpoints"
    echo ""
    
    if prompt_yes_no "Register Microsoft.Network provider now? (takes 2-5 minutes)" "y"; then
      echo ""
      echo "⏳ Registering Microsoft.Network provider..."
      echo "   This may take 2-5 minutes..."
      echo ""
      
      az provider register \
        --namespace Microsoft.Network \
        --subscription $DB_SUBSCRIPTION_ID \
        --wait
      
      # Verify registration
      FINAL_STATUS=$(az provider show \
        --namespace Microsoft.Network \
        --subscription $DB_SUBSCRIPTION_ID \
        --query registrationState -o tsv)
      
      if [ "$FINAL_STATUS" == "Registered" ]; then
        echo "Microsoft.Network provider registered successfully!"
      else
        echo " Registration failed or still in progress (status: $FINAL_STATUS)"
        echo ""
        echo "Wait a few minutes and try again, or register manually:"
        echo "  az account set --subscription $DB_SUBSCRIPTION_ID"
        echo "  az provider register --namespace Microsoft.Network --wait"
        echo "  az account set --subscription $CURRENT_SUBSCRIPTION_ID"
        echo ""
        az account set --subscription $CURRENT_SUBSCRIPTION_ID
        exit 1
      fi
    else
      echo ""
      echo "
 Cannot proceed without Microsoft.Network provider"
      echo ""
      echo "To register manually, run:"
      echo "  az account set --subscription $DB_SUBSCRIPTION_ID"
      echo "  az provider register --namespace Microsoft.Network --wait"
      echo "  az account set --subscription $CURRENT_SUBSCRIPTION_ID"
      echo ""
      echo "Then re-run this script."
      echo ""
      az account set --subscription $CURRENT_SUBSCRIPTION_ID
      exit 1
    fi
  else
    echo "  Microsoft.Network provider already registered"
  fi
  
  # Switch back to JIT subscription
  echo ""
  echo "Switching back to JIT subscription..."
  az account set --subscription $CURRENT_SUBSCRIPTION_ID
  echo "Ready to create private endpoint"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating Private Endpoint"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PE_NAME="${DB_SERVER_NAME}-jit-pe"
PE_CONNECTION="${DB_SERVER_NAME}-jit-connection"

echo ""
echo "Private endpoint name: $PE_NAME"
echo "Creating in subnet: private-endpoint-subnet"
echo ""

# Create private endpoint
if az network private-endpoint create \
  --resource-group $RESOURCE_GROUP \
  --name $PE_NAME \
  --vnet-name $VNET_NAME \
  --subnet private-endpoint-subnet \
  --private-connection-resource-id $DB_RESOURCE_ID \
  --group-id $GROUP_ID \
  --connection-name $PE_CONNECTION \
  --location $LOCATION \
  --output none 2>&1; then
  
  echo "Private endpoint created successfully"
else
  echo ""
  echo "
 Private endpoint creation failed"
  echo ""
  echo "Common issues:"
  echo "  1. Check if Microsoft.Network is registered in both subscriptions"
  echo "  2. Verify you have permissions in both subscriptions"
  echo "  3. Ensure database allows private endpoints"
  echo ""
  exit 1
fi

# Get private IP
DB_PRIVATE_IP=$(az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name $PE_NAME \
  --query "customDnsConfigs[0].ipAddresses[0]" \
  --output tsv)

echo "   Private IP: $DB_PRIVATE_IP"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Configuring Private DNS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# DNS zone based on database type
case $DB_TYPE in
  sql)
    DNS_ZONE="privatelink.database.windows.net"
    ;;
  postgresql)
    DNS_ZONE="privatelink.postgres.database.azure.com"
    ;;
  mysql)
    DNS_ZONE="privatelink.mysql.database.azure.com"
    ;;
esac

echo ""
echo "DNS Zone: $DNS_ZONE"

# Create private DNS zone
if az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name $DNS_ZONE \
  --output none 2>/dev/null; then
  echo "  DNS zone created"
else
  echo "    DNS zone already exists"
fi

# Link to VNet
if az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name $DNS_ZONE \
  --name "${DB_SERVER_NAME}-dns-link" \
  --virtual-network $VNET_NAME \
  --registration-enabled false \
  --output none 2>/dev/null; then
  echo "  VNet linked to DNS zone"
else
  echo "    VNet link already exists"
fi

# Create DNS A record
az network private-dns record-set a create \
  --resource-group $RESOURCE_GROUP \
  --zone-name $DNS_ZONE \
  --name $DB_SERVER_NAME \
  --output none 2>/dev/null || true

az network private-dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name $DNS_ZONE \
  --record-set-name $DB_SERVER_NAME \
  --ipv4-address $DB_PRIVATE_IP \
  --output none

echo "  DNS A record created"
echo "     FQDN: ${DB_SERVER_NAME}.${DNS_ZONE} → $DB_PRIVATE_IP"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Testing Connectivity from Jump Box"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Determine port based on DB type
case $DB_TYPE in
  sql)
    DB_PORT=1433
    ;;
  postgresql)
    DB_PORT=5432
    ;;
  mysql)
    DB_PORT=3306
    ;;
esac

echo ""
echo "Testing DNS resolution and port connectivity..."
echo ""

TEST_SCRIPT=$(cat <<TESTEOF
#!/bin/bash
echo "=== DNS Resolution ==="
nslookup ${DB_SERVER_NAME}.${DNS_ZONE} || true
echo ""
echo "=== Port ${DB_PORT} Connectivity ==="
nc -zv -w5 ${DB_SERVER_NAME}.${DNS_ZONE} ${DB_PORT} 2>&1 || true
TESTEOF
)

CONNECTIVITY_RESULT=$(az vm run-command invoke \
  --resource-group $RESOURCE_GROUP \
  --name $JUMPBOX_VM_NAME \
  --command-id RunShellScript \
  --scripts "$TEST_SCRIPT" \
  --query "value[0].message" -o tsv 2>/dev/null || echo "Failed to test")

echo "$CONNECTIVITY_RESULT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Database Connection Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Private Endpoint:  $PE_NAME"
echo "Private IP:        $DB_PRIVATE_IP"
echo "DNS Zone:          $DNS_ZONE"
echo "FQDN:              ${DB_SERVER_NAME}.${DNS_ZONE}"
echo "Port:              $DB_PORT"
echo ""

if [ "$CROSS_SUBSCRIPTION" = true ]; then
  echo "Cross-subscription private endpoint created successfully!"
  echo ""
  echo "Subscriptions involved:"
  echo "  JIT (PE):      $CURRENT_SUBSCRIPTION_ID"
  echo "  Database:      $DB_SUBSCRIPTION_ID"
  echo ""
fi

echo "Next steps:"
echo "  1. Configure database firewall to allow private endpoint"
echo "  2. Disable public access on database (recommended)"
echo "  3. Test connection from jump box:"
echo ""
case $DB_TYPE in
  mysql)
    echo "     mysql -h ${DB_SERVER_NAME}.${DNS_ZONE} -u admin -p"
    ;;
  postgresql)
    echo "     psql -h ${DB_SERVER_NAME}.${DNS_ZONE} -U admin -d postgres"
    ;;
  sql)
    echo "     sqlcmd -S ${DB_SERVER_NAME}.${DNS_ZONE} -U admin"
    ;;
esac
echo ""

# Save connection details
cat > ~/db-connection-${DB_SERVER_NAME}.env <<EOF
# Database Connection Details
DB_TYPE=$DB_TYPE
DB_SERVER_NAME=$DB_SERVER_NAME
DB_RESOURCE_GROUP=$DB_RESOURCE_GROUP
DB_SUBSCRIPTION_ID=$DB_SUBSCRIPTION_ID
DB_PRIVATE_IP=$DB_PRIVATE_IP
DB_FQDN=${DB_SERVER_NAME}.${DNS_ZONE}
DB_PORT=$DB_PORT
PE_NAME=$PE_NAME
CROSS_SUBSCRIPTION=$CROSS_SUBSCRIPTION
CREATED_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "📝 Connection details saved to: ~/db-connection-${DB_SERVER_NAME}.env"
echo ""