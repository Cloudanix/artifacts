#!/bin/bash
# 01-setup-infrastructure.sh
# Purpose: Complete JIT infrastructure setup

set -e

echo "=== JIT Infrastructure Setup ==="
echo ""

# Prompts with defaults
read -p "Project ID [cloud-project-id]: " PROJECT_ID
PROJECT_ID=${PROJECT_ID:-cloud-project-id}

read -p "Region [us-central1]: " REGION
REGION=${REGION:-us-central1}

read -p "Zone [us-central1-a]: " ZONE
ZONE=${ZONE:-us-central1-a}

read -p "Resource prefix [cdx]: " PREFIX
PREFIX=${PREFIX:-cdx}

# Resource naming
NETWORK_NAME="${PREFIX}-jit-network"
SUBNET_NAME="${PREFIX}-jit-subnet"
ROUTER_NAME="${PREFIX}-jit-router"
NAT_NAME="${PREFIX}-jit-nat"
CLUSTER_NAME="${PREFIX}-jit-cluster"
NFS_VM="${PREFIX}-nfs-server"
JUMP_VM="${PREFIX}-jit-jump-vm"
BASTION_VM="${PREFIX}-gke-bastion"
BUCKET_NAME="${PREFIX}-jit-storage-${PROJECT_ID}"
SECRET_NAME="${PREFIX}-jit-secrets"

# Tags
TAGS="owner=cloudanix,service=iap-proxy,purpose=cdx-jit-db"

# Input: Network CIDR
read -p "Network CIDR [10.236.0.0/16]: " NETWORK_CIDR
NETWORK_CIDR=${NETWORK_CIDR:-10.236.0.0/16}

# Calculate ILB IPs
SUBNET_BASE=$(echo $NETWORK_CIDR | cut -d. -f1-3)
PROXYSQL_ILB="${SUBNET_BASE}.101"
PROXYSERVER_ILB="${SUBNET_BASE}.102"
DAM_SERVER_ILB="${SUBNET_BASE}.103"

AR_LOCATION=$REGION
read -p "Artifact Registry images repo [cdx-jit-db-artifacts]: " AR_REPO
AR_REPO=${AR_REPO:-cdx-jit-db-artifacts}

# Input: Secret Manager values
echo ""
echo "Secret Manager Configuration:"
read -p "CDX_AUTH_TOKEN: " CDX_AUTH_TOKEN
read -p "CDX_SIGNATURE_SECRET_KEY: " CDX_SIGNATURE_SECRET_KEY
read -p "CDX_SENTRY_DSN: " CDX_SENTRY_DSN
read -p "CDX_DC: " CDX_DC
read -p "CDX_API_BASE: " CDX_API_BASE
read -p "ENCRYPTION_KEY: " ENCRYPTION_KEY

# Generate POSTGRES_PASSWORD
POSTGRES_PASSWORD=$(openssl rand -base64 32)

echo ""
echo "Configuration Summary:"
echo "  Project: $PROJECT_ID"
echo "  Region: $REGION"
echo "  Zone: $ZONE"
echo "  Prefix: $PREFIX"
echo "  Network CIDR: $NETWORK_CIDR"
echo "  ILB IPs: $PROXYSQL_ILB, $PROXYSERVER_ILB, $DAM_SERVER_ILB"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

# Create VPC
echo "Creating VPC network..."
if ! gcloud compute networks describe $NETWORK_NAME --project=$PROJECT_ID &>/dev/null; then
  gcloud compute networks create $NETWORK_NAME \
    --project=$PROJECT_ID \
    --subnet-mode=custom \
    --bgp-routing-mode=regional \
    --quiet
fi

# Create Subnet
if ! gcloud compute networks subnets describe $SUBNET_NAME --region=$REGION --project=$PROJECT_ID &>/dev/null; then
  gcloud compute networks subnets create $SUBNET_NAME \
    --project=$PROJECT_ID \
    --network=$NETWORK_NAME \
    --region=$REGION \
    --range=$NETWORK_CIDR \
    --enable-private-ip-google-access \
    --quiet
fi

# Create Cloud Router
if ! gcloud compute routers describe $ROUTER_NAME --region=$REGION --project=$PROJECT_ID &>/dev/null; then
  gcloud compute routers create $ROUTER_NAME \
    --project=$PROJECT_ID \
    --network=$NETWORK_NAME \
    --region=$REGION \
    --quiet
fi

# Create Cloud NAT
if ! gcloud compute routers nats describe $NAT_NAME --router=$ROUTER_NAME --region=$REGION --project=$PROJECT_ID &>/dev/null; then
  gcloud compute routers nats create $NAT_NAME \
    --project=$PROJECT_ID \
    --router=$ROUTER_NAME \
    --region=$REGION \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --quiet
fi

# Firewall rules
echo "Creating firewall rules..."
gcloud compute firewall-rules create ${PREFIX}-allow-iap --network=$NETWORK_NAME --allow=tcp:22,tcp:3306,tcp:5432 --source-ranges=35.235.240.0/20 --project=$PROJECT_ID --quiet 2>/dev/null || true
gcloud compute firewall-rules create ${PREFIX}-allow-internal --network=$NETWORK_NAME --allow=tcp,udp,icmp --source-ranges=10.0.0.0/8 --project=$PROJECT_ID --quiet 2>/dev/null || true
gcloud compute firewall-rules create ${PREFIX}-allow-health-check --network=$NETWORK_NAME --allow=tcp --source-ranges=35.191.0.0/16,130.211.0.0/22 --project=$PROJECT_ID --quiet 2>/dev/null || true

# Create GCS Bucket
echo "Creating Cloud Storage bucket..."
gsutil mb -p $PROJECT_ID -c STANDARD -l $REGION gs://${BUCKET_NAME}/ 2>/dev/null || true
for kv in $(echo $TAGS | tr ',' ' '); do
  key=$(echo $kv | cut -d= -f1)
  value=$(echo $kv | cut -d= -f2)
  gsutil label ch -l ${key}:${value} gs://${BUCKET_NAME}/ 2>/dev/null || true
done

# Create Secret Manager
echo "Creating Secret Manager..."
SECRET_JSON=$(cat <<EOF
{
  "CDX_AUTH_TOKEN": "$CDX_AUTH_TOKEN",
  "CDX_SIGNATURE_SECRET_KEY": "$CDX_SIGNATURE_SECRET_KEY",
  "CDX_SENTRY_DSN": "$CDX_SENTRY_DSN",
  "CDX_DC": "$CDX_DC",
  "CDX_API_BASE": "$CDX_API_BASE",
  "CDX_LOGGING_GCS_BUCKET": "$BUCKET_NAME",
  "POSTGRES_PASSWORD": "$POSTGRES_PASSWORD",
  "ENCRYPTION_KEY": "$ENCRYPTION_KEY",
  "GCP_PROJECT_ID": "$PROJECT_ID",
  "CDX_DEFAULT_REGION": "$REGION"
}
EOF
)

if gcloud secrets describe $SECRET_NAME --project=$PROJECT_ID &>/dev/null; then
  echo "$SECRET_JSON" | gcloud secrets versions add $SECRET_NAME --data-file=- --project=$PROJECT_ID
else
  gcloud secrets create $SECRET_NAME --replication-policy=automatic --project=$PROJECT_ID
  echo "$SECRET_JSON" | gcloud secrets versions add $SECRET_NAME --data-file=- --project=$PROJECT_ID
fi

# Create GKE Cluster
echo "Creating GKE cluster (10-15 min)..."
if ! gcloud container clusters describe $CLUSTER_NAME --zone=$ZONE --project=$PROJECT_ID &>/dev/null; then
  gcloud container clusters create $CLUSTER_NAME \
    --project=$PROJECT_ID \
    --zone=$ZONE \
    --network=$NETWORK_NAME \
    --subnetwork=$SUBNET_NAME \
    --enable-ip-alias \
    --enable-private-nodes \
    --enable-private-endpoint \
    --master-ipv4-cidr=172.16.0.0/28 \
    --enable-master-authorized-networks \
    --master-authorized-networks=$NETWORK_CIDR \
    --machine-type=e2-medium \
    --num-nodes=3 \
    --disk-type=pd-standard \
    --disk-size=20 \
    --workload-pool=${PROJECT_ID}.svc.id.goog \
    --addons=GcpFilestoreCsiDriver \
    --enable-secret-manager \
    --labels=$(echo $TAGS | tr ',' '\n' | paste -sd,) \
    --quiet
fi

# Create NFS Server
echo "Creating NFS server..."
cat > /tmp/nfs-startup.sh <<'EOF'
#!/bin/bash
apt-get update -qq
apt-get install -y nfs-kernel-server curl

NETWORK_CIDR=$(curl -sH "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/network-cidr)

SUBNET_BASE=$(echo $NETWORK_CIDR | cut -d. -f1-3)

if ! mountpoint -q /mnt/nfs-data; then
  mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/sdb
  mkdir -p /mnt/nfs-data
  mount -o discard,defaults /dev/sdb /mnt/nfs-data
  echo "/dev/sdb /mnt/nfs-data ext4 discard,defaults,nofail 0 2" >> /etc/fstab
fi

mkdir -p /mnt/nfs-data/exports/proxysql
chmod 777 /mnt/nfs-data/exports/proxysql
echo "/mnt/nfs-data/exports/proxysql ${SUBNET_BASE}.0/24(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
exportfs -ra
systemctl restart nfs-kernel-server
systemctl enable nfs-kernel-server
EOF

if ! gcloud compute instances describe $NFS_VM --zone=$ZONE --project=$PROJECT_ID &>/dev/null; then
  gcloud compute instances create $NFS_VM \
    --zone=$ZONE \
    --machine-type=e2-micro \
    --subnet=$SUBNET_NAME \
    --no-address \
    --tags=nfs-server \
    --labels=$(echo $TAGS | tr ',' '\n' | paste -sd,) \
    --create-disk=device-name=${NFS_VM}-data,size=20,type=pd-standard \
    --boot-disk-size=10GB \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --metadata=network-cidr=$NETWORK_CIDR \
    --metadata-from-file=startup-script=/tmp/nfs-startup.sh \
    --project=$PROJECT_ID \
    --quiet
fi

gcloud compute firewall-rules create ${PREFIX}-allow-nfs --network=$NETWORK_NAME --allow=tcp:111,tcp:2049,tcp:20048,udp:111,udp:2049,udp:20048 --source-ranges=$NETWORK_CIDR --target-tags=nfs-server --project=$PROJECT_ID --quiet 2>/dev/null || true

NFS_IP=$(gcloud compute instances describe $NFS_VM --zone=$ZONE --project=$PROJECT_ID --format='value(networkInterfaces[0].networkIP)')

# Create Jump VM
echo "Creating jump VM..."
cat > /tmp/jump-startup.sh <<'EOF'
#!/bin/bash
set -e

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  socat default-mysql-client postgresql-client \
  telnet netcat-openbsd curl jq vim htop

PROXYSQL_ILB=$(curl -sfH "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/proxysql-ilb)

PROXYSERVER_ILB=$(curl -sfH "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/proxyserver-ilb)

DAM_SERVER_ILB=$(curl -sfH "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/dam-server-ilb)

declare -A SERVICES=(
  ["proxysql-mysql"]="6033:${PROXYSQL_ILB}"
  ["proxysql-psql"]="6133:${PROXYSQL_ILB}"
  ["proxyserver"]="8079:${PROXYSERVER_ILB}"
  ["dam-server"]="8080:${DAM_SERVER_ILB}"
)

for name in "${!SERVICES[@]}"; do
  port=$(echo "${SERVICES[$name]}" | cut -d: -f1)
  ilb=$(echo "${SERVICES[$name]}" | cut -d: -f2)

  cat > /etc/systemd/system/socat-${name}.service <<SVC
[Unit]
Description=Socat forward to ${name}
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${port},fork,reuseaddr TCP:${ilb}:${port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable socat-${name}.service
  systemctl restart socat-${name}.service
done

echo "alias check-services='systemctl status socat-*'" >> /root/.bashrc
echo "Setup completed at $(date)" > /var/log/startup-complete.txt
EOF

if ! gcloud compute instances describe $JUMP_VM --zone=$ZONE --project=$PROJECT_ID &>/dev/null; then
  gcloud compute instances create $JUMP_VM \
    --zone=$ZONE \
    --machine-type=e2-medium \
    --subnet=$SUBNET_NAME \
    --no-address \
    --tags=jump-vm \
    --labels=$(echo $TAGS | tr ',' '\n' | paste -sd,) \
    --metadata=proxysql-ilb=$PROXYSQL_ILB,proxyserver-ilb=$PROXYSERVER_ILB,dam-server-ilb=$DAM_SERVER_ILB \
    --metadata-from-file=startup-script=/tmp/jump-startup.sh \
    --boot-disk-size=20GB \
    --project=$PROJECT_ID \
    --quiet
fi

# Create GKE Bastion with full cloud-platform scope
echo "Creating GKE bastion..."
cat > /tmp/bastion-startup.sh <<'EOF'
#!/bin/bash
apt-get update -qq
apt-get install -y kubectl google-cloud-sdk-gke-gcloud-auth-plugin git
EOF

if ! gcloud compute instances describe $BASTION_VM --zone=$ZONE --project=$PROJECT_ID &>/dev/null; then
  gcloud compute instances create $BASTION_VM \
    --zone=$ZONE \
    --machine-type=e2-medium \
    --subnet=$SUBNET_NAME \
    --no-address \
    --tags=gke-bastion \
    --labels=$(echo $TAGS | tr ',' '\n' | paste -sd,) \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --metadata-from-file=startup-script=/tmp/bastion-startup.sh \
    --boot-disk-size=20GB \
    --project=$PROJECT_ID \
    --quiet
fi

# Grant bastion VM permissions
BASTION_SA=$(gcloud compute instances describe $BASTION_VM --zone=$ZONE --project=$PROJECT_ID --format='value(serviceAccounts[0].email)')
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${BASTION_SA}" --role="roles/resourcemanager.projectIamAdmin" --condition=None --quiet >/dev/null 2>&1
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${BASTION_SA}" --role="roles/container.developer" --condition=None --quiet >/dev/null 2>&1
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${BASTION_SA}" --role="roles/iam.serviceAccountAdmin" --condition=None --quiet >/dev/null 2>&1

rm -f /tmp/*-startup.sh

# Save configuration for next scripts
cat > /tmp/jit-config.env <<EOF
PROJECT_ID=$PROJECT_ID
REGION=$REGION
ZONE=$ZONE
PREFIX=$PREFIX
NETWORK_CIDR=$NETWORK_CIDR
PROXYSQL_ILB=$PROXYSQL_ILB
PROXYSERVER_ILB=$PROXYSERVER_ILB
DAM_SERVER_ILB=$DAM_SERVER_ILB
AR_LOCATION=$AR_LOCATION
AR_REPO=$AR_REPO
CLUSTER_NAME=$CLUSTER_NAME
NETWORK_NAME=$NETWORK_NAME
SUBNET_NAME=$SUBNET_NAME
NFS_VM=$NFS_VM
BASTION_VM=$BASTION_VM
SECRET_NAME=$SECRET_NAME
NFS_IP=$NFS_IP
EOF

echo ""
echo "=== Infrastructure Ready ==="
echo ""
echo "Network: $NETWORK_NAME ($NETWORK_CIDR)"
echo "Cluster: $CLUSTER_NAME (3x e2-medium)"
echo "NFS Server: $NFS_VM ($NFS_IP)"
echo "Jump VM: $JUMP_VM"
echo "Bastion: $BASTION_VM"
echo "Bucket: gs://${BUCKET_NAME}"
echo "Secrets: $SECRET_NAME"
echo ""
echo "Configuration saved to: /tmp/jit-config.env"
echo ""
echo "Next: SSH to bastion and run workload identity setup"
echo "  gcloud compute ssh $BASTION_VM --zone=$ZONE --tunnel-through-iap --project=$PROJECT_ID"
echo "  # Upload jit-config.env to bastion, then:"
echo "  source jit-config.env"
echo "  ./02-setup-workload-identity.sh"
echo ""
