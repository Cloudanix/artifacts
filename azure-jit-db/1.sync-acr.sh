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
echo "Azure Container Registry Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Source (Cloudanix) ACR details
SOURCE_ACR_NAME="cdxjitacr111"
SOURCE_ACR_SERVER="${SOURCE_ACR_NAME}.azurecr.io"
SKIP_ACR_CREATION=false
RESOURCE_GROUP="jit-db-rg"
echo ""
echo "Checking resource group: $RESOURCE_GROUP"

RG_EXISTS=$(az group exists --name $RESOURCE_GROUP)
if [ "$RG_EXISTS" = "false" ]; then
  echo "Resource group not found"
  read -p "Location for resource group [eastus]: " RG_LOCATION
  RG_LOCATION=${RG_LOCATION:-eastus}
  echo "Creating resource group: $RESOURCE_GROUP in $RG_LOCATION..."
  az group create \
    --name $RESOURCE_GROUP \
    --location $RG_LOCATION \
    --output none
  
  echo " Resource group created"
  LOCATION=$RG_LOCATION
else
  echo " Resource group found"
  # Get location from existing resource group
  LOCATION=$(az group show --name $RESOURCE_GROUP --query location -o tsv)
  echo "   Location: $LOCATION"
fi

# Check for existing ACR
echo ""
echo "Checking for existing ACR in resource group..."

EXISTING_ACR=$(az acr list --resource-group $RESOURCE_GROUP \
  --query "[?starts_with(name, 'jitacr')].name" -o tsv | head -1)

if [ -n "$EXISTING_ACR" ]; then
  echo "  Found existing ACR: $EXISTING_ACR"
  echo ""
  
  if prompt_yes_no "Use existing ACR instead of creating new one?" "y"; then
    ACR_NAME="$EXISTING_ACR"
    ACR_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
    
    echo " Using existing ACR: $ACR_SERVER"
    echo ""
    echo "Skipping ACR creation, proceeding to image sync..."
    
    # Skip to managed identity check
    SKIP_ACR_CREATION=true
  else
    # Auto-generate new ACR name
    RANDOM_SUFFIX=$(openssl rand -hex 4 | head -c 7)
    ACR_NAME="jitacr${RANDOM_SUFFIX}"
    SKIP_ACR_CREATION=false
    
    echo ""
    echo "Generated new ACR name: $ACR_NAME"
    echo "Location: $LOCATION"
  fi
else
  # Auto-generate ACR name (jitacr + 7 random digits)
  RANDOM_SUFFIX=$(openssl rand -hex 4 | head -c 7)
  ACR_NAME="jitacr${RANDOM_SUFFIX}"
  SKIP_ACR_CREATION=false
  
  echo "No existing ACR found"
  echo ""
  echo "Generated ACR name: $ACR_NAME"
  echo "Location: $LOCATION"
fi

# Collect other inputs
read -p "Image tag to import [latest]: " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-latest}

echo ""
ENABLE_DAM=false
if prompt_yes_no "Enable Database Activity Monitoring (DAM)?" "n"; then
  ENABLE_DAM=true
  echo "  DAM will be enabled (5 images)"
else
  echo "  DAM will be disabled (3 images)"
fi

# Create ACR only if we're not using an existing one
if [ "$SKIP_ACR_CREATION" = false ]; then
  echo ""
  echo "Creating ACR: $ACR_NAME"

  # Check and register Azure Container Registry provider
  echo "Checking resource provider registration..."
  PROVIDER_STATE=$(az provider show --namespace Microsoft.ContainerRegistry --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")

  if [ "$PROVIDER_STATE" != "Registered" ]; then
    echo "  Microsoft.ContainerRegistry provider not registered"
    echo "Registering provider (this may take 1-2 minutes)..."
    
    az provider register --namespace Microsoft.ContainerRegistry --wait
    
    echo " Provider registered"
  else
    echo " Provider already registered"
  fi

  # Create ACR (Basic SKU)
  echo "Creating ACR..."
  az acr create \
    --resource-group $RESOURCE_GROUP \
    --name $ACR_NAME \
    --sku Basic \
    --admin-enabled true \
    --location $LOCATION \
    --output none

  ACR_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)

  echo " ACR created: $ACR_SERVER"
fi

# Grant managed identity pull access to ACR (if infrastructure exists)
echo ""
echo "Checking for managed identity..."

if [ ! -f ~/jit-infra.env ]; then
  echo "  Infrastructure not yet set up (~/jit-infra.env not found)"
  echo ""
else
  # Save our newly generated ACR_NAME before sourcing config
  NEW_ACR_NAME="$ACR_NAME"
  NEW_ACR_SERVER="$ACR_SERVER"
  
  source ~/jit-infra.env
  
  # Restore our newly generated ACR name (don't use old one from config)
  ACR_NAME="$NEW_ACR_NAME"
  ACR_SERVER="$NEW_ACR_SERVER"
  
  if [ -z "$IDENTITY_PRINCIPAL_ID" ] || [ -z "$IDENTITY_NAME" ]; then
    echo "  Managed identity not found in config"
    echo "   Run ./2.setup-infra.sh to create managed identity"
  else
    echo "Found managed identity: $IDENTITY_NAME"
    echo "Granting AcrPull role to $IDENTITY_NAME..."
    
    ACR_ID=$(az acr show --name $ACR_NAME --query id -o tsv)
    az role assignment create \
      --assignee $IDENTITY_PRINCIPAL_ID \
      --role AcrPull \
      --scope $ACR_ID \
      --output none 2>/dev/null && echo " AcrPull role assigned" || echo "  Role assignment failed (may already exist)"
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Docker Login to Source and Target ACRs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Login to source ACR (Cloudanix provides pull-only token)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "IMPORTANT: Cloudanix Pull-Only Token Required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Press Enter when you have received the token credentials..."
echo ""
read -p "Cloudanix ACR token username: " SOURCE_USER
read -s -p "Cloudanix ACR token password: " SOURCE_PASS
echo ""

echo "Authenticating to Cloudanix ACR..."
echo "$SOURCE_PASS" | docker login $SOURCE_ACR_SERVER \
  --username $SOURCE_USER \
  --password-stdin

# Login to target ACR (customer)
echo "Authenticating to your ACR..."
az acr login --name $ACR_NAME

echo " Docker authenticated to both ACRs"
echo "   Cloudanix ACR: Pull-only access"
echo "   Your ACR:      Full access"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Importing Images"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Images to import
IMAGES=(
  "cloudanix/ecr-aws-jit-proxy-sql"
  "cloudanix/ecr-aws-jit-proxy-server"
  "cloudanix/ecr-aws-jit-query-logging"
)

if [ "$ENABLE_DAM" = true ]; then
  IMAGES+=(
    "cloudanix/ecr-aws-jit-dam-server"
    "cloudanix/ecr-aws-jit-postgresql"
  )
fi

for IMAGE in "${IMAGES[@]}"; do
  echo ""
  echo "🔄 Processing: ${IMAGE}:${IMAGE_TAG}"
  
  SOURCE_IMAGE="${SOURCE_ACR_SERVER}/${IMAGE}:${IMAGE_TAG}"
  TARGET_IMAGE="${ACR_SERVER}/${IMAGE}:${IMAGE_TAG}"
  TARGET_IMAGE_LATEST="${ACR_SERVER}/${IMAGE}:latest"
  
  echo "  Pulling from source..."
  docker pull --platform linux/amd64 "$SOURCE_IMAGE"
  
  echo "  Tagging for target..."
  docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"
  docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE_LATEST"
  
  echo "  Pushing to target..."
  docker push "$TARGET_IMAGE"
  docker push "$TARGET_IMAGE_LATEST"
  
  echo "   ${IMAGE}"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Remove source credentials
docker logout $SOURCE_ACR_SERVER

echo " Source credentials removed"

# Save ACR details to config
echo ""
echo "Updating configuration..."

if [ -f ~/jit-infra.env ]; then
  # Update existing config
  sed -i.bak "s|^ACR_NAME=.*|ACR_NAME=$ACR_NAME|g" ~/jit-infra.env
  sed -i.bak "s|^ACR_SERVER=.*|ACR_SERVER=$ACR_SERVER|g" ~/jit-infra.env
  rm -f ~/jit-infra.env.bak
  echo " Updated ~/jit-infra.env with ACR details"
else
  echo "~/jit-infra.env not found - run 2.setup-infra.sh first"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "ACR Name:   $ACR_NAME"
echo "ACR Server: $ACR_SERVER"
echo ""
echo "Images imported:"
az acr repository list --name $ACR_NAME --output table
echo ""