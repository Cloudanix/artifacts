#!/bin/bash

set +e
echo "JIT Infrastructure Cleanup Script"
echo "================================="
echo ""

# Get project ID
read -p "Project ID to clean up: " PROJECT_ID
if [ -z "$PROJECT_ID" ]; then
  echo "Error: Project ID required"
  exit 1
fi

read -p "Region [us-central1]: " REGION
REGION=${REGION:-us-central1}

read -p "Zone [us-central1-a]: " ZONE
ZONE=${ZONE:-us-central1-a}

read -p "Resource prefix [cdx]: " PREFIX
PREFIX=${PREFIX:-cdx}

echo ""
echo "This will delete ALL resources in project: $PROJECT_ID"
echo "Prefix: $PREFIX"
echo "Region: $REGION"
echo ""
read -p "Are you sure? Type 'DELETE' to confirm: " CONFIRM

if [ "$CONFIRM" != "DELETE" ]; then
  echo "Cleanup cancelled"
  exit 0
fi

echo ""
echo "Starting cleanup..."
echo ""

# Resource names
CLUSTER_NAME="${PREFIX}-jit-cluster"
NETWORK_NAME="${PREFIX}-jit-network"
SUBNET_NAME="${PREFIX}-jit-subnet"
ROUTER_NAME="${PREFIX}-jit-router"
NAT_NAME="${PREFIX}-jit-nat"
NFS_VM="${PREFIX}-nfs-server"
JUMP_VM="${PREFIX}-jit-jump-vm"
BASTION_VM="${PREFIX}-gke-bastion"
SECRET_NAME="${PREFIX}-jit-secrets"
GCP_SA="${PREFIX}-jit-workload-sa"
AR_REPO="cdx-jit-db-artifacts"

# Function to delete with error handling
delete_resource() {
  local cmd="$1"
  local desc="$2"
  echo "Deleting $desc..."
  eval "$cmd --quiet 2>/dev/null" || echo "  Not found or already deleted"
}

# 1. Delete GKE cluster
echo "[1/15] GKE Cluster"
delete_resource \
  "gcloud container clusters delete $CLUSTER_NAME --zone=$ZONE --project=$PROJECT_ID" \
  "GKE cluster"

# 2. Delete VMs
echo "[2/15] Compute Instances"
for vm in $NFS_VM $JUMP_VM $BASTION_VM; do
  delete_resource \
    "gcloud compute instances delete $vm --zone=$ZONE --project=$PROJECT_ID" \
    "VM: $vm"
done

# 3. Delete PSC endpoints
echo "[3/15] PSC Endpoints"
PSC_ENDPOINTS=$(gcloud compute forwarding-rules list --project=$PROJECT_ID --format="value(name)" --filter="name~psc-endpoint" 2>/dev/null)
for endpoint in $PSC_ENDPOINTS; do
  delete_resource \
    "gcloud compute forwarding-rules delete $endpoint --region=$REGION --project=$PROJECT_ID" \
    "PSC endpoint: $endpoint"
done

# 4. Delete PSC reserved IPs
echo "[4/15] PSC Reserved IPs"
PSC_IPS=$(gcloud compute addresses list --project=$PROJECT_ID --format="value(name)" --filter="name~psc-ip" 2>/dev/null)
for ip in $PSC_IPS; do
  delete_resource \
    "gcloud compute addresses delete $ip --region=$REGION --project=$PROJECT_ID" \
    "PSC IP: $ip"
done

# 5. Delete Cloud NAT
echo "[5/15] Cloud NAT"
delete_resource \
  "gcloud compute routers nats delete $NAT_NAME --router=$ROUTER_NAME --region=$REGION --project=$PROJECT_ID" \
  "Cloud NAT"

# 6. Delete Cloud Router
echo "[6/15] Cloud Router"
delete_resource \
  "gcloud compute routers delete $ROUTER_NAME --region=$REGION --project=$PROJECT_ID" \
  "Cloud Router"

# 7. Delete Firewall Rules
echo "[7/15] Firewall Rules"
FW_RULES=$(gcloud compute firewall-rules list --project=$PROJECT_ID --format="value(name)" --filter="network~$NETWORK_NAME" 2>/dev/null)
for rule in $FW_RULES; do
  delete_resource \
    "gcloud compute firewall-rules delete $rule --project=$PROJECT_ID" \
    "Firewall rule: $rule"
done

# 8. Delete Subnet
echo "[8/15] Subnet"
delete_resource \
  "gcloud compute networks subnets delete $SUBNET_NAME --region=$REGION --project=$PROJECT_ID" \
  "Subnet"

# 9. Delete VPC Network
echo "[9/15] VPC Network"
delete_resource \
  "gcloud compute networks delete $NETWORK_NAME --project=$PROJECT_ID" \
  "VPC Network"

# 10. Delete GCS Buckets
echo "[10/15] GCS Buckets"
BUCKETS=$(gsutil ls -p $PROJECT_ID 2>/dev/null | grep "${PREFIX}-jit-storage" || true)
for bucket in $BUCKETS; do
  echo "Deleting bucket: $bucket"
  gsutil -m rm -r "$bucket" 2>/dev/null || echo "  Not found or already deleted"
done

# 11. Delete Secret Manager Secrets
echo "[11/15] Secret Manager"
delete_resource \
  "gcloud secrets delete $SECRET_NAME --project=$PROJECT_ID" \
  "Secret: $SECRET_NAME"

# 12. Delete Service Accounts
echo "[12/15] Service Accounts"
SAS=$(gcloud iam service-accounts list --project=$PROJECT_ID --format="value(email)" --filter="email~${PREFIX}" 2>/dev/null)
for sa in $SAS; do
  echo "Deleting service account: $sa"
  gcloud iam service-accounts delete $sa --project=$PROJECT_ID --quiet 2>/dev/null || echo "  Not found or already deleted"
done

# 13. Delete Artifact Registry
echo "[13/15] Artifact Registry"
delete_resource \
  "gcloud artifacts repositories delete $AR_REPO --location=$REGION --project=$PROJECT_ID" \
  "Artifact Registry: $AR_REPO"

# 14. Delete disk snapshots (if any)
echo "[14/15] Disk Snapshots"
SNAPSHOTS=$(gcloud compute snapshots list --project=$PROJECT_ID --format="value(name)" --filter="name~${PREFIX}" 2>/dev/null)
for snapshot in $SNAPSHOTS; do
  delete_resource \
    "gcloud compute snapshots delete $snapshot --project=$PROJECT_ID" \
    "Snapshot: $snapshot"
done

# 15. Delete orphaned disks
echo "[15/15] Orphaned Disks"
DISKS=$(gcloud compute disks list --project=$PROJECT_ID --format="value(name,zone)" --filter="name~${PREFIX} AND -users:*" 2>/dev/null)
echo "$DISKS" | while read disk zone; do
  if [ ! -z "$disk" ]; then
    zone_short=$(echo $zone | rev | cut -d/ -f1 | rev)
    delete_resource \
      "gcloud compute disks delete $disk --zone=$zone_short --project=$PROJECT_ID" \
      "Disk: $disk"
  fi
done

echo ""
echo "================================="
echo "Cleanup complete"
echo ""
echo "Remaining resources (if any):"
echo ""
echo "VMs:"
gcloud compute instances list --project=$PROJECT_ID --filter="name~${PREFIX}" 2>/dev/null || echo "  None"
echo ""
echo "Networks:"
gcloud compute networks list --project=$PROJECT_ID --filter="name~${PREFIX}" 2>/dev/null || echo "  None"
echo ""
echo "Service Accounts:"
gcloud iam service-accounts list --project=$PROJECT_ID --filter="email~${PREFIX}" 2>/dev/null || echo "  None"
echo ""
echo "Note: Some resources may take a few minutes to fully delete"
echo ""