#!/bin/bash
# 03-setup-psc-cloudsql.sh
# Purpose: Setup Private Service Connect endpoint for Cloud SQL

set -e

# Configuration
JIT_PROJECT="${JIT_PROJECT:-cloud-project-id}"
JIT_NETWORK="${JIT_NETWORK:-cdx-jit-network}"
JIT_SUBNET="${JIT_SUBNET:-cdx-jit-subnet}"
REGION="${REGION:-us-central1}"

echo "=== PSC Cloud SQL Setup ==="
echo ""

# Input: Cloud SQL details
read -p "Cloud SQL project ID [$JIT_PROJECT]: " DB_PROJECT
DB_PROJECT=${DB_PROJECT:-$JIT_PROJECT}

read -p "Cloud SQL instance name: " DB_INSTANCE
[ -z "$DB_INSTANCE" ] && { echo "Instance name required"; exit 1; }

read -p "Desired PSC endpoint IP (e.g., 10.0.1.108): " PSC_IP
[ -z "$PSC_IP" ] && { echo "IP address required"; exit 1; }

ENDPOINT_NAME="${DB_INSTANCE}-psc-endpoint"
IP_NAME="${DB_INSTANCE}-psc-ip"

echo ""
echo "Configuration:"
echo "  DB Project: $DB_PROJECT"
echo "  DB Instance: $DB_INSTANCE"
echo "  JIT Project: $JIT_PROJECT"
echo "  JIT Network: $JIT_NETWORK"
echo "  PSC IP: $PSC_IP"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

# Enable PSC on Cloud SQL
echo "Enabling PSC on Cloud SQL instance..."
gcloud sql instances patch $DB_INSTANCE \
  --enable-private-service-connect \
  --allowed-psc-projects=$JIT_PROJECT \
  --project=$DB_PROJECT \
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
