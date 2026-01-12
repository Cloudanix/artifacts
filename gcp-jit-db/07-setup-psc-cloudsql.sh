#!/bin/bash
# 03-setup-psc-cloudsql.sh
# Purpose: Setup Private Service Connect endpoint for Cloud SQL

set -e

echo "=== PSC Cloud SQL Setup ==="
echo ""

# Configuration
# Input: Cloud SQL details
read -p "JIT Proxy Project ID [cdx-jit-db-proxy]: " JIT_PROJECT
JIT_PROJECT=${JIT_PROJECT:-cdx-jit-db-proxy}

read -p "JIT Network name [cdx-jit-network]: " JIT_NETWORK
JIT_NETWORK="${JIT_NETWORK:-cdx-jit-network}"

read -p "JIT Subnet name [cdx-jit-subnet]: " JIT_SUBNET
JIT_SUBNET="${JIT_SUBNET:-cdx-jit-subnet}"

read -p "Cloud SQL project ID [cloud-project-id]: " DB_PROJECT
DB_PROJECT=${DB_PROJECT:-cloud-project-id}

read -p "Cloud SQL instance name: " DB_INSTANCE
[ -z "$DB_INSTANCE" ] && { echo "Instance name required"; exit 1; }

read -p "Desired Private Service Connect endpoint IP (e.g., 10.236.1.108): " PSC_IP
[ -z "$PSC_IP" ] && { echo "IP address required"; exit 1; }

read -p "Cloud SQL region (e.g., us-central1): " REGION
REGION="${REGION:-us-central1}"

ENDPOINT_NAME="${DB_INSTANCE}-psc-endpoint"
IP_NAME="${DB_INSTANCE}-psc-ip"

echo ""
echo "Configuration:"
echo "  Region: $REGION"
echo "  DB Project: $DB_PROJECT"
echo "  DB Instance: $DB_INSTANCE"
echo "  JIT Project: $JIT_PROJECT"
echo "  JIT Network: $JIT_NETWORK"
echo "  JIT Subnet: $JIT_SUBNET"
echo "  Private Service Connect IP: $PSC_IP"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

# Enable PSC on Cloud SQL
echo "Enabling PSC on Cloud SQL instance..."
PSC_PRIMARY_IP="$(echo "$PSC_IP" | sed 's/\./_/g')"

gcloud sql instances patch $DB_INSTANCE \
  --enable-private-service-connect \
  --allowed-psc-projects=$JIT_PROJECT \
  --project=$DB_PROJECT \
  --quiet

gcloud beta sql instances patch $DB_INSTANCE \
  --project=$DB_PROJECT \
  --update-labels psc_primary_ip=$PSC_PRIMARY_IP,psc_consumer_project=$JIT_PROJECT,psc_region=$REGION \
  --quiet

# Wait for operation
echo "Waiting for PSC enablement..."
sleep 30

# Get service attachment
echo "Getting service attachment..."
SERVICE_ATTACHMENT=$(gcloud sql instances describe $DB_INSTANCE \
  --project=$DB_PROJECT \
  --format="value(pscServiceAttachmentLink)")

if [ -z "$SERVICE_ATTACHMENT" ]; then
  echo "Error: Service attachment not found"
  echo "Cloud SQL instance may not support PSC or operation still in progress"
  exit 1
fi

echo "Service attachment: $SERVICE_ATTACHMENT"

# Find subnet in DB region
echo ""
echo "Looking for subnet in $REGION..."
JIT_SUBNET=$(gcloud compute networks subnets list \
  --network=$JIT_NETWORK \
  --project=$JIT_PROJECT \
  --filter="region:$REGION" \
  --format="value(name)" \
  --limit=1 2>/dev/null)

if [ -z "$JIT_SUBNET" ]; then
  echo "No subnet found in $REGION"
  echo ""
  
  # Auto-create subnet
  NEW_SUBNET_NAME="cdx-jit-subnet-${REGION}"
  
  # Get existing CIDRs to avoid conflicts
  EXISTING_CIDRS=$(gcloud compute networks subnets list \
    --network=$JIT_NETWORK \
    --project=$JIT_PROJECT \
    --format="value(ipCidrRange)" 2>/dev/null)
  
  # Suggest non-conflicting CIDR
  if echo "$EXISTING_CIDRS" | grep -q "10.238."; then
    DEFAULT_CIDR="10.239.0.0/16"
  elif echo "$EXISTING_CIDRS" | grep -q "10.239."; then
    DEFAULT_CIDR="10.240.0.0/16"
  elif echo "$EXISTING_CIDRS" | grep -q "10.240."; then
    DEFAULT_CIDR="10.241.0.0/16"
  else
    DEFAULT_CIDR="10.238.0.0/16"
  fi
  
  echo "Creating new subnet for PSC endpoint"
  
  echo ""
  echo "Will create:"
  echo "  Name: $NEW_SUBNET_NAME"
  echo "  Region: $REGION"
  echo "  CIDR: $DEFAULT_CIDR"
  echo ""
  read -p "Create subnet? (y/n) " -n 1 -r
  echo
  
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cannot proceed without subnet in $REGION"
    exit 1
  fi
  
  echo "Creating subnet..."
  gcloud compute networks subnets create $NEW_SUBNET_NAME \
    --network=$JIT_NETWORK \
    --region=$REGION \
    --range=$DEFAULT_CIDR \
    --enable-private-ip-google-access \
    --project=$JIT_PROJECT \
    --quiet

  JIT_SUBNET=$NEW_SUBNET_NAME
  SUBNET_CIDR=$DEFAULT_CIDR
  echo "Subnet created"
else
  echo "Found subnet: $JIT_SUBNET"
  SUBNET_CIDR=$(gcloud compute networks subnets describe $JIT_SUBNET \
    --region=$REGION \
    --project=$JIT_PROJECT \
    --format="value(ipCidrRange)")
fi

echo ""
echo "Using subnet: $JIT_SUBNET ($SUBNET_CIDR)"

# Create IP address reservation
echo "Reserving IP address..."
if ! gcloud compute addresses describe $IP_NAME --region=$REGION --project=$JIT_PROJECT &>/dev/null; then
  gcloud compute addresses create $IP_NAME \
    --project=$JIT_PROJECT \
    --region=$REGION \
    --subnet=$JIT_SUBNET \
    --addresses=$PSC_IP \
    --quiet
fi

# Create PSC forwarding rule
echo "Creating PSC endpoint..."
if gcloud compute forwarding-rules describe $ENDPOINT_NAME --region=$REGION --project=$JIT_PROJECT &>/dev/null; then
  echo "Endpoint already exists"
else
  gcloud compute forwarding-rules create $ENDPOINT_NAME \
    --address=$IP_NAME \
    --project=$JIT_PROJECT \
    --region=$REGION \
    --network=$JIT_NETWORK \
    --target-service-attachment=$SERVICE_ATTACHMENT \
    --allow-psc-global-access \
    --quiet
fi

# Verify endpoint
echo "Verifying endpoint..."
ENDPOINT_IP=$(gcloud compute forwarding-rules describe $ENDPOINT_NAME \
  --region=$REGION \
  --project=$JIT_PROJECT \
  --format="value(IPAddress)")

echo ""
echo "=== PSC Endpoint Ready ==="
echo ""
echo "Cloud SQL: $DB_INSTANCE (project: $DB_PROJECT)"
echo "PSC Endpoint: $ENDPOINT_IP"
