#!/bin/bash
# upload-config-to-bastion.sh
# Purpose: Upload jit-config.env to bastion VM

set -e

if [ ! -f "/tmp/jit-config.env" ]; then
  echo "Error: /tmp/jit-config.env not found"
  echo "Please run 01-setup-infrastructure.sh first"
  exit 1
fi

source /tmp/jit-config.env

echo "Uploading config to bastion: $BASTION_VM"
echo ""

gcloud compute scp /tmp/jit-config.env ${BASTION_VM}:/tmp/jit-config.env \
  --zone=$ZONE \
  --tunnel-through-iap \
  --project=$PROJECT_ID

echo ""
echo "Config uploaded successfully!"
echo ""
echo "Now SSH to bastion and run setup:"
echo "  gcloud compute ssh $BASTION_VM --zone=$ZONE --tunnel-through-iap --project=$PROJECT_ID"
echo "  source jit-config.env"
echo "  ./02-setup-workload-identity.sh"
echo ""
