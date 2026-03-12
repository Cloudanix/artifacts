#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================
# Script 2: JIT Database Access Infrastructure Setup
#
# Creates complete Azure infrastructure:
# - VNet with subnets (jump box, ACI, private endpoints)
# - Jump Box VM with Entra ID SSH authentication
# - Key Vault (RBAC mode) with all required secrets
# - Storage accounts (SMB for proxysql-data, Blob for logs)
# - Managed Identity with all necessary roles
# - Socat port forwarding on Jump Box
# - Saves configuration to ~/jit-infra.env
# ============================================================

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  read -p "$prompt [$default_value]: " user_input
  echo "${user_input:-$default_value}"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "JIT Database Access - Infrastructure Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Collect Configuration ──────────────────────────────────
RESOURCE_GROUP=$(prompt_with_default "Resource Group name" "jit-db-rg")
LOCATION=$(prompt_with_default "Azure location" "eastus")
VNET_NAME=$(prompt_with_default "VNet name" "jit-vnet")
VNET_PREFIX=$(prompt_with_default "VNet address prefix" "10.0.0.0/16")

echo ""
echo "Subnet planning (within $VNET_PREFIX):"
JUMPBOX_SUBNET_PREFIX=$(prompt_with_default "  Jump Box subnet" "10.0.3.0/24")
ACI_SUBNET_PREFIX=$(prompt_with_default "  ACI subnet (min /24)" "10.0.6.0/24")
PE_SUBNET_PREFIX=$(prompt_with_default "  Private Endpoint subnet" "10.0.7.0/24")

echo ""
JUMPBOX_VM_NAME=$(prompt_with_default "Jump Box VM name" "jumpbox-vm")
JUMPBOX_ADMIN_USER=$(prompt_with_default "Jump Box admin username" "azureuser")

echo ""
echo "Storage:"
SMB_STORAGE_NAME=$(prompt_with_default "SMB storage account name (unique)" "jitsmb$(date +%s)")
BLOB_STORAGE_NAME=$(prompt_with_default "Blob storage account name (unique)" "jitblob$(date +%s)")

echo ""
echo "Key Vault:"
KEYVAULT_NAME=$(prompt_with_default "Key Vault name (unique)" "jit-kv-$(date +%s)")

echo ""
echo "Managed Identity:"
IDENTITY_NAME=$(prompt_with_default "Managed Identity name" "cdx-jit-identity")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Secrets Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Cloudanix API credentials (from Cloudanix support):"
read -p "CDX_AUTH_TOKEN: " CDX_AUTH_TOKEN
read -p "CDX_SIGNATURE_SECRET_KEY: " CDX_SIGN_KEY
read -p "CDX_SENTRY_DSN (optional): " CDX_SENTRY
CDX_DC=$(prompt_with_default "CDX_DC (region)" "US")
CDX_API=$(prompt_with_default "CDX_API_BASE" "https://console.cloudanix.com")

echo ""
echo "PostgreSQL configuration:"
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
echo "Generated PostgreSQL password: $POSTGRES_PASSWORD"

ENCRYPTION_KEY=$(openssl rand -hex 16)
echo "Generated encryption key: $ENCRYPTION_KEY"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating Infrastructure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── STEP 0: Register Resource Providers ───────────────────
echo ""
echo "[0/12] Checking resource provider registrations..."

PROVIDERS=(
  "Microsoft.Network"
  "Microsoft.Compute"
  "Microsoft.Storage"
  "Microsoft.KeyVault"
  "Microsoft.ManagedIdentity"
  "Microsoft.ContainerInstance"
  "Microsoft.ContainerRegistry"
)

NEEDS_REGISTRATION=false
for PROVIDER in "${PROVIDERS[@]}"; do
  STATE=$(az provider show --namespace $PROVIDER --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
  
  if [ "$STATE" != "Registered" ]; then
    echo "    $PROVIDER: Not registered"
    NEEDS_REGISTRATION=true
  else
    echo "   $PROVIDER: Registered"
  fi
done

if [ "$NEEDS_REGISTRATION" = true ]; then
  echo ""
  echo "Registering required providers (this may take 2-3 minutes)..."
  
  for PROVIDER in "${PROVIDERS[@]}"; do
    STATE=$(az provider show --namespace $PROVIDER --query "registrationState" -o tsv 2>/dev/null)
    
    if [ "$STATE" != "Registered" ]; then
      echo "  Registering $PROVIDER..."
      az provider register --namespace $PROVIDER --wait
    fi
  done
  
  echo " All providers registered"
fi

# ── STEP 1: Resource Group ────────────────────────────────
echo ""
echo "[1/12] Creating resource group..."

RG_EXISTS=$(az group exists --name $RESOURCE_GROUP)
if [ "$RG_EXISTS" = "true" ]; then
  echo "   $RESOURCE_GROUP (already exists)"
else
  az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION \
    --output none
  echo "   $RESOURCE_GROUP (created)"
fi

# ── STEP 2: VNet & Subnets ────────────────────────────────
echo ""
echo "[2/12] Creating VNet and subnets..."
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefix $VNET_PREFIX \
  --location $LOCATION \
  --output none

az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name jumpbox-subnet \
  --address-prefix $JUMPBOX_SUBNET_PREFIX \
  --output none

az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aci-subnet \
  --address-prefix $ACI_SUBNET_PREFIX \
  --output none

# Delegate ACI subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aci-subnet \
  --delegations Microsoft.ContainerInstance/containerGroups \
  --output none

az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name private-endpoint-subnet \
  --address-prefix $PE_SUBNET_PREFIX \
  --output none

echo "   VNet: $VNET_NAME"
echo "   Subnets: jumpbox, aci, private-endpoint"

# ── STEP 3: Jump Box VM ────────────────────────────────────
echo ""
echo "[3/12] Creating Jump Box VM with Entra ID SSH..."

# Public IP
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name jumpbox-public-ip \
  --sku Standard \
  --location $LOCATION \
  --output none

# NSG
az network nsg create \
  --resource-group $RESOURCE_GROUP \
  --name jumpbox-nsg \
  --location $LOCATION \
  --output none

# Get allowed IPs for SSH
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SSH Access Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "For security, SSH access should be restricted to specific IPs."
echo ""
read -p "Do you have a VPN IP/CIDR to whitelist? (y/n): " HAS_VPN

ALLOWED_IPS=()

if [ "$HAS_VPN" = "y" ]; then
  read -p "Enter VPN IP or CIDR block (e.g., 203.0.113.0/24): " VPN_IP
  ALLOWED_IPS+=("$VPN_IP")
  echo "  Added VPN: $VPN_IP"
else
  echo ""
  echo "Getting your current public IP..."
  MY_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip)
  
  if [ -n "$MY_IP" ]; then
    echo "  Your IP: $MY_IP"
    read -p "Whitelist your current IP ($MY_IP/32)? (y/n) [y]: " WHITELIST_ME
    WHITELIST_ME=${WHITELIST_ME:-y}
    
    if [ "$WHITELIST_ME" = "y" ]; then
      ALLOWED_IPS+=("${MY_IP}/32")
      echo "  Added: ${MY_IP}/32"
    fi
  else
    echo "  Could not detect your IP"
  fi
fi

echo ""
read -p "Add additional IPs? (y/n) [n]: " ADD_MORE
ADD_MORE=${ADD_MORE:-n}

while [ "$ADD_MORE" = "y" ]; do
  read -p "Enter IP or CIDR: " EXTRA_IP
  ALLOWED_IPS+=("$EXTRA_IP")
  echo "  Added: $EXTRA_IP"
  read -p "Add another? (y/n) [n]: " ADD_MORE
  ADD_MORE=${ADD_MORE:-n}
done

# Create NSG rule with allowed IPs
if [ ${#ALLOWED_IPS[@]} -eq 0 ]; then
  echo ""
  echo "  WARNING: No IPs specified. Creating rule with 0.0.0.0/0 (open to internet)"
  read -p "Continue? (y/n): " CONFIRM
  if [ "$CONFIRM" != "y" ]; then
    echo "Aborting setup"
    exit 1
  fi
  ALLOWED_IPS=("*")
fi

echo ""
echo "Creating NSG rule with allowed sources:"
for IP in "${ALLOWED_IPS[@]}"; do
  echo "  $IP"
done

az network nsg rule create \
  --resource-group $RESOURCE_GROUP \
  --nsg-name jumpbox-nsg \
  --name AllowSSH \
  --priority 1000 \
  --source-address-prefixes "${ALLOWED_IPS[@]}" \
  --destination-port-ranges 22 \
  --protocol Tcp \
  --access Allow \
  --output none

echo "  SSH access restricted to specified IPs"

# Associate NSG with subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name jumpbox-subnet \
  --network-security-group jumpbox-nsg \
  --output none

# Create VM with system-assigned managed identity (for Entra ID SSH)
echo "Creating VM..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $JUMPBOX_VM_NAME \
  --location $LOCATION \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username $JUMPBOX_ADMIN_USER \
  --authentication-type ssh \
  --generate-ssh-keys \
  --vnet-name $VNET_NAME \
  --subnet jumpbox-subnet \
  --public-ip-address jumpbox-public-ip \
  --nsg jumpbox-nsg \
  --assign-identity \
  --output none

echo "Waiting 60s for VM identity to propagate..."
sleep 60

# Enable Entra ID login extension (requires system-assigned identity)
echo "Installing Entra ID SSH extension..."
az vm extension set \
  --resource-group $RESOURCE_GROUP \
  --vm-name $JUMPBOX_VM_NAME \
  --name AADSSHLoginForLinux \
  --publisher Microsoft.Azure.ActiveDirectory \
  --output none

JUMPBOX_PUBLIC_IP=$(az network public-ip show \
  --resource-group $RESOURCE_GROUP \
  --name jumpbox-public-ip \
  --query ipAddress -o tsv)

echo "   Jump Box: $JUMPBOX_VM_NAME"
echo "   Public IP: $JUMPBOX_PUBLIC_IP"

# ── STEP 4: Storage Accounts ───────────────────────────────
echo ""
echo "[4/12] Creating storage accounts..."

# SMB storage for proxysql-data
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $SMB_STORAGE_NAME \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --output none

az storage share create \
  --account-name $SMB_STORAGE_NAME \
  --name proxysql-data \
  --quota 50 \
  --output none

# Blob storage for audit logs
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $BLOB_STORAGE_NAME \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --output none

az storage container create \
  --account-name $BLOB_STORAGE_NAME \
  --name jit-db-logs \
  --auth-mode login \
  --output none

echo "   SMB storage: $SMB_STORAGE_NAME"
echo "   Blob storage: $BLOB_STORAGE_NAME"

# ── STEP 5: Key Vault ──────────────────────────────────────
echo ""
echo "[5/12] Creating Key Vault (RBAC mode)..."
az keyvault create \
  --resource-group $RESOURCE_GROUP \
  --name $KEYVAULT_NAME \
  --location $LOCATION \
  --sku standard \
  --enable-rbac-authorization true \
  --output none

echo "   Key Vault: $KEYVAULT_NAME"

# ── STEP 6: Managed Identity ───────────────────────────────
echo ""
echo "[6/12] Creating managed identity..."
az identity create \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --location $LOCATION \
  --output none

IDENTITY_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query id -o tsv)

IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query clientId -o tsv)

IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $IDENTITY_NAME \
  --query principalId -o tsv)

echo "   Identity: $IDENTITY_NAME"
echo "   Client ID: $IDENTITY_CLIENT_ID"

# Wait for propagation
echo "  Waiting 30s for identity propagation..."
sleep 30

# ── STEP 7: Role Assignments ───────────────────────────────
echo ""
echo "[7/12] Assigning roles to managed identity..."

# Key Vault Secrets User
KV_ID=$(az keyvault show --name $KEYVAULT_NAME --query id -o tsv)
az role assignment create \
  --assignee $IDENTITY_PRINCIPAL_ID \
  --role "Key Vault Secrets User" \
  --scope $KV_ID \
  --output none
echo "   Key Vault Secrets User"

# Storage Blob Data Contributor
BLOB_ID=$(az storage account show \
  --resource-group $RESOURCE_GROUP \
  --name $BLOB_STORAGE_NAME \
  --query id -o tsv)
az role assignment create \
  --assignee $IDENTITY_PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope $BLOB_ID \
  --output none
echo "   Storage Blob Data Contributor"

# ACR Pull (if ACR already exists from running 1.sync-acr.sh first)
ACR_LIST=$(az acr list --resource-group $RESOURCE_GROUP --query "[?starts_with(name, 'jitacr')].name" -o tsv)
if [ -n "$ACR_LIST" ]; then
  for ACR in $ACR_LIST; do
    echo "  Found ACR: $ACR - granting AcrPull..."
    ACR_ID=$(az acr show --name $ACR --query id -o tsv)
    az role assignment create \
      --assignee $IDENTITY_PRINCIPAL_ID \
      --role AcrPull \
      --scope $ACR_ID \
      --output none 2>/dev/null || true
    echo "   AcrPull (ACR: $ACR)"
  done
fi

# ── STEP 8: Store Secrets in Key Vault ────────────────────
echo ""
echo "[8/12] Storing secrets in Key Vault..."

# Get current user to temporarily grant Key Vault admin
CURRENT_USER=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee $CURRENT_USER \
  --role "Key Vault Secrets Officer" \
  --scope $KV_ID \
  --output none
sleep 10  # Wait for role to propagate

# Store all secrets
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-APP-ENV"               --value "production" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-LOG-LEVEL"             --value "DEBUG" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-PROXY-SERVER-VERSION"  --value "0.3.14" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-LOG-MANAGER-VERSION"   --value "0.3.14" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-DEFAULT-REGION"        --value "us-east-1" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-DC"                    --value "$CDX_DC" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-API-BASE"              --value "$CDX_API" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-AUTH-TOKEN"            --value "$CDX_AUTH_TOKEN" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-SIGNATURE-SECRET-KEY"  --value "$CDX_SIGN_KEY" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-SENTRY-DSN"            --value "$CDX_SENTRY" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "POSTGRES-PASSWORD"         --value "$POSTGRES_PASSWORD" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "ENCRYPTION-KEY"            --value "$ENCRYPTION_KEY" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "CDX-LOGGING-AZURE-CONTAINER" --value "jit-db-logs" --output none
az keyvault secret set --vault-name $KEYVAULT_NAME --name "AZURE-STORAGE-ACCOUNT-URL" --value "https://${BLOB_STORAGE_NAME}.blob.core.windows.net/" --output none

echo "   All secrets stored"

# Remove temporary admin role
az role assignment delete \
  --assignee $CURRENT_USER \
  --role "Key Vault Secrets Officer" \
  --scope $KV_ID \
  --output none 2>/dev/null || true

# ── STEP 9: Jump Box Configuration ─────────────────────────
echo ""
echo "[9/12] Configuring Jump Box with socat..."

# Expected ACI IPs (will be set after deployment)
PROXYSQL_IP="10.0.6.5"
PROXYSERVER_IP="10.0.6.6"
DAMSERVER_IP="10.0.6.8"

# Create socat setup script
cat > /tmp/jumpbox-setup.sh << 'SETUPEOF'
#!/bin/bash
set -e

echo "Installing tools..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  socat default-mysql-client postgresql-client \
  telnet netcat-openbsd curl jq vim htop

echo "Creating socat systemd services..."

# Define essential port forwards
declare -A FORWARDS=(
  ["proxysql-psql"]="6133:10.0.6.5:6133"
  ["proxysql-mysql"]="6033:10.0.6.5:6033"
  ["dam-server"]="8080:10.0.6.8:8080"
  ["proxyserver"]="8079:10.0.6.6:8079"
)

for name in "${!FORWARDS[@]}"; do
  local_port=$(echo "${FORWARDS[$name]}" | cut -d: -f1)
  target_ip=$(echo "${FORWARDS[$name]}" | cut -d: -f2)
  target_port=$(echo "${FORWARDS[$name]}" | cut -d: -f3)

  cat > /etc/systemd/system/socat-${name}.service << SVC
[Unit]
Description=Socat forward to ${name} (${target_ip}:${target_port})
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${local_port},fork,reuseaddr TCP:${target_ip}:${target_port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable socat-${name}.service
  systemctl start socat-${name}.service
  echo "   socat-${name}: localhost:${local_port} → ${target_ip}:${target_port}"
done

# Create helper aliases
cat >> /etc/bash.bashrc << 'ALIASES'

# JIT Database Access Aliases
alias socat-status='systemctl status socat-*'
alias socat-list='systemctl list-units socat-*.service'
alias socat-logs='journalctl -u socat-* -f'
alias check-aci='echo "Testing ACI connectivity..."; nc -w3 -vz 10.0.6.5 6133 2>&1 | grep -q succeeded && echo " proxysql-psql" || echo "❌ proxysql-psql"; nc -w3 -vz 10.0.6.5 6033 2>&1 | grep -q succeeded && echo " proxysql-mysql" || echo "❌ proxysql-mysql"; nc -w3 -vz 10.0.6.6 8079 2>&1 | grep -q succeeded && echo " proxyserver" || echo "❌ proxyserver"; nc -w3 -vz 10.0.6.8 8080 2>&1 | grep -q succeeded && echo " dam-server" || echo "❌ dam-server"'
ALIASES

echo ""
echo "Jump Box configuration complete!"
echo "Socat services running. Check with: systemctl status socat-*"
SETUPEOF

# Upload and execute
az vm run-command invoke \
  --resource-group $RESOURCE_GROUP \
  --name $JUMPBOX_VM_NAME \
  --command-id RunShellScript \
  --scripts @/tmp/jumpbox-setup.sh \
  --output none

echo "   Jump Box configured with socat port forwarding"

# ── STEP 10: Save Configuration ────────────────────────────
echo ""
echo "[10/12] Saving configuration..."

# Check if ACR already exists (from running 1.sync-acr.sh first)
ACR_NAME=""
ACR_SERVER=""

ACR_LIST=$(az acr list --resource-group $RESOURCE_GROUP --query "[?starts_with(name, 'jitacr')].name" -o tsv)
if [ -n "$ACR_LIST" ]; then
  ACR_NAME=$(echo "$ACR_LIST" | head -1)
  ACR_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
  echo "  Found existing ACR: $ACR_NAME"
fi

cat > ~/jit-infra.env << EOF
RESOURCE_GROUP=$RESOURCE_GROUP
LOCATION=$LOCATION
VNET_NAME=$VNET_NAME
KEYVAULT_NAME=$KEYVAULT_NAME
IDENTITY_NAME=$IDENTITY_NAME
IDENTITY_ID=$IDENTITY_ID
IDENTITY_CLIENT_ID=$IDENTITY_CLIENT_ID
IDENTITY_PRINCIPAL_ID=$IDENTITY_PRINCIPAL_ID
SMB_STORAGE_NAME=$SMB_STORAGE_NAME
BLOB_STORAGE_NAME=$BLOB_STORAGE_NAME
ACR_NAME=$ACR_NAME
ACR_SERVER=$ACR_SERVER
JUMPBOX_VM_NAME=$JUMPBOX_VM_NAME
JUMPBOX_PUBLIC_IP=$JUMPBOX_PUBLIC_IP
EOF

# Save credentials to separate file
cat > ~/jit-infra-credentials.txt << CREDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
JIT Infrastructure Credentials
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PostgreSQL Password:  $POSTGRES_PASSWORD
Encryption Key:       $ENCRYPTION_KEY

  IMPORTANT: Keep this file secure and delete after noting credentials!

All secrets are stored in Key Vault: $KEYVAULT_NAME
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREDS

chmod 600 ~/jit-infra-credentials.txt

echo "   Configuration saved to ~/jit-infra.env"
echo "   Credentials saved to ~/jit-infra-credentials.txt (chmod 600)"

# ── STEP 11: Summary ───────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Infrastructure Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Resource Group:    $RESOURCE_GROUP"
echo "VNet:              $VNET_NAME ($VNET_PREFIX)"
echo "Jump Box:          $JUMPBOX_PUBLIC_IP"
echo "Key Vault:         $KEYVAULT_NAME"
echo "Managed Identity:  $IDENTITY_NAME"
echo "SMB Storage:       $SMB_STORAGE_NAME"
echo "Blob Storage:      $BLOB_STORAGE_NAME"
if [ -n "$ACR_NAME" ]; then
  echo "ACR:               $ACR_SERVER"
fi
echo ""
echo "📝 Credentials:"
echo "   Auto-generated PostgreSQL password saved to ~/jit-infra-credentials.txt"
echo "   All secrets stored in Key Vault: $KEYVAULT_NAME"
echo ""