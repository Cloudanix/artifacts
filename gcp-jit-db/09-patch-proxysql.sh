#!/bin/bash
set -e

NAMESPACE="jit-services"

echo "=== Add SSL Certificates to ProxySQL ==="
echo ""

# Check if cert files exist
if [ ! -f /tmp/client-cert.pem ]; then
  echo "Error: /tmp/client-cert.pem not found"
  exit 1
fi

if [ ! -f /tmp/client-key.pem ]; then
  echo "Error: /tmp/client-key.pem not found"
  exit 1
fi

if [ ! -f /tmp/server-ca.pem ]; then
  echo "Error: /tmp/server-ca.pem not found"
  exit 1
fi

echo "Certificate files found:"
echo "  /tmp/client-cert.pem"
echo "  /tmp/client-key.pem"
echo "  /tmp/server-ca.pem"
echo ""

# Create or update secret
echo "Creating Kubernetes secret..."
kubectl delete secret proxysql-ssl-certs -n $NAMESPACE 2>/dev/null || true

kubectl create secret generic proxysql-ssl-certs \
  --from-file=client-cert.pem=/tmp/client-cert.pem \
  --from-file=client-key.pem=/tmp/client-key.pem \
  --from-file=server-ca.pem=/tmp/server-ca.pem \
  -n $NAMESPACE

echo "Secret created"
echo ""

# Patch ProxySQL deployment
echo "Updating ProxySQL deployment..."

# Create patch file
cat > /tmp/proxysql-ssl-patch.yaml <<'EOF'
spec:
  template:
    spec:
      initContainers:
      - name: fix-permissions
        image: busybox
        command: 
          - sh
          - -c
          - |
            chown -R 1000:1000 /var/lib/proxysql
            mkdir -p /var/lib/proxysql/certs
            chown -R 1000:1000 /var/lib/proxysql/certs
            chmod 755 /var/lib/proxysql/certs
            if [ -d /ssl-certs ]; then
              cp /ssl-certs/* /var/lib/proxysql/certs/
              chown 1000:1000 /var/lib/proxysql/certs/*
              chmod 600 /var/lib/proxysql/certs/*.pem
            fi
        volumeMounts:
        - name: proxysql-data
          mountPath: /var/lib/proxysql
        - name: ssl-certs
          mountPath: /ssl-certs
          readOnly: true
      volumes:
      - name: proxysql-data
        persistentVolumeClaim:
          claimName: proxysql-pvc
      - name: secrets-store
        csi:
          driver: secrets-store-gke.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: cdx-secrets-provider
      - name: ssl-certs
        secret:
          secretName: proxysql-ssl-certs
          defaultMode: 0600
EOF

# Apply patch
kubectl patch deployment proxysql -n $NAMESPACE --patch-file /tmp/proxysql-ssl-patch.yaml

echo "Deployment patched"
echo ""

# Wait for rollout
echo "Waiting for rollout to complete..."
kubectl rollout status deployment/proxysql -n $NAMESPACE --timeout=5m

echo ""
echo " SSL Certificates Added Successfully "