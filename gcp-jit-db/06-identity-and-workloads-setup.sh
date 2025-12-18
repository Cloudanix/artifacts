#!/bin/bash
# 03-identity-and-workloads-setup.sh
# Purpose: Setup Workload Identity and generate Kubernetes manifest
# Run this from GKE bastion VM

set -e

# Load configuration
if [ -f "/tmp/jit-config.env" ]; then
  source /tmp/jit-config.env
  echo "Configuration loaded from /tmp/jit-config.env"
else
  echo "Error: /tmp/jit-config.env not found"
  echo "Please upload /tmp/jit-config.env from local machine or run:"
  echo "  gcloud compute scp /tmp/jit-config.env $BASTION_VM:~ --zone=$ZONE --tunnel-through-iap"
  exit 1
fi

NAMESPACE="jit-services"
K8S_SA="${PREFIX}-jit-sa"
GCP_SA="${PREFIX}-jit-workload-sa"
GCP_SA_EMAIL="${GCP_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Workload Identity Setup ==="
echo ""
echo "Project: $PROJECT_ID"
echo "Cluster: $CLUSTER_NAME"
echo "Zone: $ZONE"
echo "Namespace: $NAMESPACE"
echo "Network CIDR: $NETWORK_CIDR"
echo "ILB IPs: $PROXYSQL_ILB, $PROXYSERVER_ILB, $DAM_SERVER_ILB"
echo ""

# Get cluster credentials
echo "Connecting to cluster..."
gcloud container clusters get-credentials $CLUSTER_NAME --zone=$ZONE --project=$PROJECT_ID --quiet

# Create namespace
echo "Creating namespace..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create GCP Service Account
echo "Creating GCP service account..."
if ! gcloud iam service-accounts describe $GCP_SA_EMAIL --project=$PROJECT_ID &>/dev/null; then
  gcloud iam service-accounts create $GCP_SA --project=$PROJECT_ID --quiet
fi

# Grant IAM roles
echo "Granting IAM roles..."
for role in secretmanager.secretAccessor logging.logWriter storage.objectAdmin iam.serviceAccountTokenCreator; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${GCP_SA_EMAIL}" \
    --role="roles/${role}" \
    --condition=None \
    --quiet >/dev/null 2>&1
done

# Create K8s Service Account
echo "Creating Kubernetes service account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $K8S_SA
  namespace: $NAMESPACE
  annotations:
    iam.gke.io/gcp-service-account: $GCP_SA_EMAIL
EOF

# Bind Workload Identity
echo "Binding workload identity..."
gcloud iam service-accounts add-iam-policy-binding $GCP_SA_EMAIL \
  --project=$PROJECT_ID \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${K8S_SA}]" \
  --quiet

# Create NFS PV/PVC
echo "Creating NFS storage..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PREFIX}-proxysql-pv
  labels:
    storage: proxysql-nfs
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - hard
    - nfsvers=4.1
  nfs:
    server: $NFS_IP
    path: /mnt/nfs-data/exports/proxysql
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: proxysql-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 20Gi
  selector:
    matchLabels:
      storage: proxysql-nfs
EOF

# Create Secret Provider Class
echo "Creating secret provider class..."
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: ${PREFIX}-secrets-provider
  namespace: $NAMESPACE
spec:
  provider: gke
  parameters:
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/${SECRET_NAME}/versions/latest"
        path: "cdx-secrets.json"
EOF

# Generate Kubernetes manifest
echo "Generating Kubernetes manifest..."

# Calculate network source ranges for ILB
NETWORK_BASE=$(echo $NETWORK_CIDR | cut -d/ -f1 | cut -d. -f1-2)
ILB_SOURCE_RANGES="${NETWORK_BASE}.0.0/16"

# Image paths
POSTGRES_IMAGE="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/gcp-ar-jit-postgresql:latest"
PROXYSQL_IMAGE="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/gcp-ar-jit-proxy-sql:latest"
PROXYSERVER_IMAGE="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/gcp-ar-jit-proxy-server:latest"
QUERYLOG_IMAGE="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/gcp-ar-jit-query-logging:latest"
DAM_IMAGE="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/gcp-ar-jit-dam-server:v1.0.0"
cat > jit-service-manifest.yaml <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: jit-services
  labels:
    name: jit-services
    owner: cloudanix
    service: iap-proxy
    purpose: cdx-jit-db

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: jit-services
  labels:
    app: postgresql
    owner: cloudanix
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      serviceAccountName: $K8S_SA
      securityContext:
        fsGroup: 1000
      initContainers:
      - name: load-secrets
        image: alpine:3.19
        command:
          - sh
          - -c
          - |
            apk add --no-cache jq
            jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' /mnt/secrets-store/cdx-secrets.json > /env/.env
        volumeMounts:
        - name: secrets-store
          mountPath: /mnt/secrets-store
        - name: env-file
          mountPath: /env
      containers:
      - name: postgresql
        image: $POSTGRES_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 5432
        command:
          - sh
          - -c
          - |
            set -a
            . /env/.env
            set +a
            exec docker-entrypoint.sh postgres
        env:
        - name: POSTGRES_DB
          value: jitdb
        - name: POSTGRES_USER
          value: pgjitdbuser
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/postgresql/data
        - name: secrets-store
          mountPath: /mnt/secrets-store
          readOnly: true
        - name: env-file
          mountPath: /env
      volumes:
      - name: secrets-store
        csi:
          driver: secrets-store-gke.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: ${PREFIX}-secrets-provider
      - name: env-file
        emptyDir: {}
  volumeClaimTemplates:
  - metadata:
      name: postgresql-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: standard-rwo
      resources:
        requests:
          storage: 20Gi

---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: jit-services
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: postgresql

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: proxysql
  namespace: jit-services
  labels:
    app: proxysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: proxysql
  template:
    metadata:
      labels:
        app: proxysql
    spec:
      serviceAccountName: $K8S_SA
      securityContext:
        runAsUser: 1000
        fsGroup: 1000
      initContainers:
      - name: fix-permissions
        image: busybox
        command: ["sh", "-c", "chown -R 1000:1000 /var/lib/proxysql"]
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
      containers:
      - name: proxysql
        image: $PROXYSQL_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 6032
        - containerPort: 6033
        - containerPort: 6132
        - containerPort: 6133
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
        - name: secrets-store
          mountPath: /mnt/secrets-store
          readOnly: true
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            cpu: 1
            memory: 1Gi
      volumes:
      - name: proxysql-data
        persistentVolumeClaim:
          claimName: proxysql-pvc
      - name: secrets-store
        csi:
          driver: secrets-store-gke.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: ${PREFIX}-secrets-provider

---
apiVersion: v1
kind: Service
metadata:
  name: proxysql-ilb
  namespace: jit-services
  annotations:
    cloud.google.com/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  loadBalancerIP: $PROXYSQL_ILB
  loadBalancerSourceRanges:
  - $ILB_SOURCE_RANGES
  ports:
  - name: admin
    port: 6032
    targetPort: 6032
  - name: psql
    port: 6133
    targetPort: 6133
  - name: mysql
    port: 6033
    targetPort: 6033
  selector:
    app: proxysql

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: proxyserver
  namespace: jit-services
spec:
  replicas: 2
  selector:
    matchLabels:
      app: proxyserver
  template:
    metadata:
      labels:
        app: proxyserver
    spec:
      serviceAccountName: $K8S_SA
      securityContext:
        fsGroup: 1000
      initContainers:
      - name: load-secrets
        image: alpine:3.19
        command:
          - sh
          - -c
          - |
            apk add --no-cache jq
            jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' /mnt/secrets-store/cdx-secrets.json > /env/.env
        volumeMounts:
        - name: secrets-store
          mountPath: /mnt/secrets-store
        - name: env-file
          mountPath: /env
      containers:
      - name: proxyserver
        image: $PROXYSERVER_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 8079
        command:
          - sh
          - -c
          - |
            set -a
            . /env/.env
            set +a
            exec /app/server_proxy
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
        - name: secrets-store
          mountPath: /mnt/secrets-store
          readOnly: true
        - name: env-file
          mountPath: /env
      volumes:
      - name: proxysql-data
        persistentVolumeClaim:
          claimName: proxysql-pvc
      - name: secrets-store
        csi:
          driver: secrets-store-gke.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: ${PREFIX}-secrets-provider
      - name: env-file
        emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: proxyserver-ilb
  namespace: jit-services
  annotations:
    cloud.google.com/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  loadBalancerIP: $PROXYSERVER_ILB
  loadBalancerSourceRanges:
  - $ILB_SOURCE_RANGES
  ports:
  - port: 8079
    targetPort: 8079
  selector:
    app: proxyserver

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: query-logging
  namespace: jit-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: query-logging
  template:
    metadata:
      labels:
        app: query-logging
    spec:
      serviceAccountName: $K8S_SA
      securityContext:
        runAsUser: 0
        fsGroup: 1000
      initContainers:
      - name: load-secrets
        image: alpine:3.19
        command:
          - sh
          - -c
          - |
            apk add --no-cache jq
            jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' /mnt/secrets-store/cdx-secrets.json > /env/.env
        volumeMounts:
        - name: secrets-store
          mountPath: /mnt/secrets-store
        - name: env-file
          mountPath: /env
      - name: fix-permissions
        image: busybox
        command: ["sh", "-c", "chown -R 1000:1000 /var/lib/proxysql"]
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
      containers:
      - name: query-logging
        image: $QUERYLOG_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 8079
        command:
          - sh
          - -c
          - |
            set -a
            . /env/.env
            set +a
            exec /app/logmanager
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
        - name: secrets-store
          mountPath: /mnt/secrets-store
          readOnly: true
        - name: env-file
          mountPath: /env
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
      volumes:
      - name: proxysql-data
        persistentVolumeClaim:
          claimName: proxysql-pvc
      - name: secrets-store
        csi:
          driver: secrets-store-gke.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: ${PREFIX}-secrets-provider
      - name: env-file
        emptyDir: {}

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dam-server
  namespace: jit-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dam-server
  template:
    metadata:
      labels:
        app: dam-server
    spec:
      serviceAccountName: $K8S_SA
      securityContext:
        fsGroup: 1000
      initContainers:
      - name: load-secrets
        image: alpine:3.19
        command:
          - sh
          - -c
          - |
            apk add --no-cache jq
            jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' /mnt/secrets-store/cdx-secrets.json > /env/.env
        volumeMounts:
        - name: secrets-store
          mountPath: /mnt/secrets-store
        - name: env-file
          mountPath: /env
      containers:
      - name: dam-server
        image: $DAM_IMAGE
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        command:
          - sh
          - -c
          - |
            set -a
            . /env/.env
            set +a
            exec /usr/src/app/entrypoint.sh
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
        - name: secrets-store
          mountPath: /mnt/secrets-store
          readOnly: true
        - name: env-file
          mountPath: /env
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            cpu: 1
            memory: 1Gi
      volumes:
      - name: proxysql-data
        persistentVolumeClaim:
          claimName: proxysql-pvc
      - name: secrets-store
        csi:
          driver: secrets-store-gke.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: ${PREFIX}-secrets-provider
      - name: env-file
        emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: dam-server-ilb
  namespace: jit-services
  annotations:
    cloud.google.com/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  loadBalancerIP: $DAM_SERVER_ILB
  loadBalancerSourceRanges:
  - $ILB_SOURCE_RANGES
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: dam-server

---
# ProxySQL Service
apiVersion: v1
kind: Service
metadata:
  name: proxysql
  namespace: jit-services
  labels:
    app: proxysql
spec:
  type: ClusterIP
  ports:
  - name: admin
    port: 6032
    targetPort: 6032
    protocol: TCP
  - name: mysql
    port: 6033
    targetPort: 6033
    protocol: TCP
  selector:
    app: proxysql

---
# ProxyServer Service
apiVersion: v1
kind: Service
metadata:
  name: proxyserver
  namespace: jit-services
  labels:
    app: proxyserver
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8079
    targetPort: 8079
    protocol: TCP
  selector:
    app: proxyserver


---
# Query Logging Service
apiVersion: v1
kind: Service
metadata:
  name: query-logging
  namespace: jit-services
  labels:
    app: query-logging
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8079
    targetPort: 8079
    protocol: TCP
  selector:
    app: query-logging


---
# DAM Server Service
apiVersion: v1
kind: Service
metadata:
  name: dam-server
  namespace: jit-services
  labels:
    app: dam-server
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
  selector:
    app: dam-server

EOF

kubectl apply -f jit-service-manifest.yaml

echo ""
echo "=== Setup Complete ==="
echo ""
echo "GCP SA: $GCP_SA_EMAIL"
echo "K8s SA: $K8S_SA"
echo "NFS IP: $NFS_IP"
echo ""
echo "Manifest generated: jit-service-manifest.yaml"
echo "  - PostgreSQL: $POSTGRES_IMAGE"
echo "  - ProxySQL: $PROXYSQL_IMAGE"
echo "  - ProxyServer: $PROXYSERVER_IMAGE"
echo "  - Query Logging: $QUERYLOG_IMAGE"
echo "  - DAM Server: $DAM_IMAGE"
echo "  - ProxySQL ILB: $PROXYSQL_ILB"
echo "  - ProxyServer ILB: $PROXYSERVER_ILB"
echo "  - DAM Server ILB: $DAM_SERVER_ILB"
echo ""
echo "Next: Deploy services"
echo "  kubectl apply -f jit-service-manifest.yaml"
echo ""
echo "Verify deployment:"
echo "  kubectl get pods -n jit-services"
echo "  kubectl get svc -n jit-services"
echo ""
