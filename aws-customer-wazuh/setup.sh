#!/usr/bin/env bash
# Configure and deploy Cloudanix Wazuh into a customer AWS account.
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${ROOT}/infra/parameters.json"
NON_INTERACTIVE="${CDX_NON_INTERACTIVE:-false}"
CONFIGURE_ONLY=false
SKIP_INFRA=false
SKIP_WAZUH=false

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Options:
  --configure-only  Write parameters and certificates; do not deploy
  --skip-infra      Skip CloudFormation/EKS infrastructure
  --skip-wazuh      Skip Wazuh kustomize deployment
  --non-interactive Require all CDX_* inputs; do not prompt
  -h, --help        Show help

Non-interactive inputs:
  AWS_REGION, CDX_VPC_ID, CDX_PRIVATE_SUBNET_IDS, CDX_PUBLIC_SUBNET_IDS,
  CDX_WORKSPACE_ID, CDX_WORKSPACE_TOKEN

Optional:
  CDX_CLUSTER_NAME, CDX_KUBERNETES_VERSION, CDX_GENERAL_INSTANCE_TYPE,
  CDX_GENERAL_DESIRED_SIZE, CDX_WORKER_INSTANCE_TYPE,
  CDX_WORKER_DESIRED_SIZE, CDX_SECRET_NAME, CDX_FORWARD_TARGET,
  CDX_FORWARD_PORT, CDX_IMAGE_REGISTRY, CDX_IMAGE_TAG
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure-only) CONFIGURE_ONLY=true ;;
    --skip-infra) SKIP_INFRA=true ;;
    --skip-wazuh) SKIP_WAZUH=true ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

for tool in aws kubectl helm jq python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool not found: ${tool}" >&2
    exit 1
  }
done

ask() {
  local variable="$1" prompt="$2" default="$3" secret="${4:-false}" value
  value="${!variable:-}"
  if [[ -z "$value" && "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -n "$default" ]]; then
      value="$default"
    else
      echo "error: ${variable} is required in non-interactive mode" >&2
      exit 1
    fi
  elif [[ -z "$value" ]]; then
    if [[ "$secret" == "true" ]]; then
      read -rsp "${prompt}: " value
      echo
    else
      read -rp "${prompt} [${default}]: " value
      value="${value:-$default}"
    fi
  fi
  printf -v "$variable" '%s' "$value"
}

confirm() {
  local prompt="$1" default="${2:-n}" answer
  [[ "$NON_INTERACTIVE" == "true" ]] && return 0
  read -rp "${prompt} (y/n) [${default}]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
ask AWS_REGION "AWS region" "us-east-1"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

IDENTITY="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(jq -r '.Account' <<<"$IDENTITY")"
CALLER_ARN="$(jq -r '.Arn' <<<"$IDENTITY")"
echo "AWS account: ${ACCOUNT_ID}"
echo "Caller:      ${CALLER_ARN}"
if ! confirm "Deploy Wazuh infrastructure into this account and region ${AWS_REGION}?" n; then
  echo "Cancelled."
  exit 0
fi

IMAGE_REGISTRY="${CDX_IMAGE_REGISTRY:-public.ecr.aws/e7l2l5s1}"
IMAGE_TAG="${CDX_IMAGE_TAG:-v0.2.5}"

FORWARD_TARGET="${CDX_FORWARD_TARGET:-}"

if [[ ! -f "$PARAMS_FILE" || "${CDX_RECONFIGURE:-false}" == "true" ]]; then
  CDX_CREATE_TEST_VPC="${CDX_CREATE_TEST_VPC:-false}"
  if [[ "$NON_INTERACTIVE" != "true" && -z "${CDX_VPC_ID:-}" ]]; then
    if confirm "Create a new test VPC instead of using an existing VPC?" n; then
      CDX_CREATE_TEST_VPC=true
    fi
  fi

  ask CDX_CLUSTER_NAME "EKS cluster name" "wazuh"
  ask CDX_KUBERNETES_VERSION "Kubernetes version" "1.31"

  if [[ "$CDX_CREATE_TEST_VPC" == "true" ]]; then
    CDX_VPC_ID="vpc-created-by-cloudformation"
    CDX_PRIVATE_SUBNET_IDS="subnets-created-by-cloudformation"
    CDX_PUBLIC_SUBNET_IDS="subnets-created-by-cloudformation"
  else
    ask CDX_VPC_ID "Existing VPC ID" ""
    ask CDX_PRIVATE_SUBNET_IDS "Two private subnet IDs (comma-separated)" ""
    ask CDX_PUBLIC_SUBNET_IDS "Two public subnet IDs in different AZs (comma-separated)" ""
  fi

  ask CDX_GENERAL_INSTANCE_TYPE "General node instance type" "m5.xlarge"
  ask CDX_GENERAL_DESIRED_SIZE "General node desired count" "3"
  ask CDX_WORKER_INSTANCE_TYPE "Wazuh worker instance type" "m5.large"
  ask CDX_WORKER_DESIRED_SIZE "Wazuh worker desired count" "3"
  ask CDX_SECRET_NAME "Secrets Manager secret name" "cdx-central-vm-auth-tokens"
  ask CDX_WORKSPACE_ID "Cloudanix workspace ID/key" ""
  ask CDX_WORKSPACE_TOKEN "Cloudanix workspace token" "" true

  [[ "$CDX_VPC_ID" == vpc-* ]] || {
    [[ "$CDX_CREATE_TEST_VPC" == "true" ]] || {
      echo "error: CDX_VPC_ID must start with vpc-" >&2
      exit 1
    }
  }
  SECRET_VALUE="$(jq -cn \
    --arg key "$CDX_WORKSPACE_ID" \
    --arg value "$CDX_WORKSPACE_TOKEN" \
    '{($key): $value}')"

  umask 077
  jq -n \
    --arg cluster "$CDX_CLUSTER_NAME" \
    --arg version "$CDX_KUBERNETES_VERSION" \
    --arg vpc "$CDX_VPC_ID" \
    --arg privateSubnets "$CDX_PRIVATE_SUBNET_IDS" \
    --arg publicSubnets "$CDX_PUBLIC_SUBNET_IDS" \
    --arg generalType "$CDX_GENERAL_INSTANCE_TYPE" \
    --arg generalCount "$CDX_GENERAL_DESIRED_SIZE" \
    --arg workerType "$CDX_WORKER_INSTANCE_TYPE" \
    --arg workerCount "$CDX_WORKER_DESIRED_SIZE" \
    --arg secretName "$CDX_SECRET_NAME" \
    --arg secretValue "$SECRET_VALUE" \
    '{
      ClusterName: $cluster,
      KubernetesVersion: $version,
      VpcId: $vpc,
      PrivateSubnetIds: $privateSubnets,
      PublicSubnetIds: $publicSubnets,
      GeneralInstanceType: $generalType,
      GeneralDesiredSize: $generalCount,
      WorkerInstanceType: $workerType,
      WorkerDesiredSize: $workerCount,
      SecretName: $secretName,
      SecretValue: $secretValue
    }' > "$PARAMS_FILE"
  chmod 600 "$PARAMS_FILE"
  echo "Wrote ${PARAMS_FILE} (mode 0600)"
else
  echo "Using existing ${PARAMS_FILE}; set CDX_RECONFIGURE=true to replace it."
  CDX_CREATE_TEST_VPC="${CDX_CREATE_TEST_VPC:-false}"
fi

CERT_ROOT="${ROOT}/wazuh/base/certs"
INDEXER_CERTS="${CERT_ROOT}/indexer_cluster"
DASHBOARD_CERTS="${CERT_ROOT}/dashboard_http"
if [[ ! -s "${INDEXER_CERTS}/root-ca.pem" ||
      ! -s "${INDEXER_CERTS}/node-key.pem" ||
      ! -s "${DASHBOARD_CERTS}/key.pem" ]]; then
  echo "==> Generating customer-specific TLS certificates"
  mkdir -p "$INDEXER_CERTS" "$DASHBOARD_CERTS"
  for file in \
    root-ca-key.pem root-ca.pem root-ca.srl \
    admin-key-temp.pem admin-key.pem admin.csr admin.pem \
    node-key-temp.pem node-key.pem node.csr node.pem \
    dashboard-key-temp.pem dashboard-key.pem dashboard.csr dashboard.pem \
    filebeat-key-temp.pem filebeat-key.pem filebeat.csr filebeat.pem; do
    rm -f "${INDEXER_CERTS}/${file}"
  done
  rm -f "${DASHBOARD_CERTS}/key.pem" "${DASHBOARD_CERTS}/cert.pem"
  (
    cd "$INDEXER_CERTS"
    ./generate_certs.sh
  )
  (
    cd "$DASHBOARD_CERTS"
    ./generate_certs.sh
  )
  chmod 600 "${INDEXER_CERTS}/"*-key.pem \
    "${INDEXER_CERTS}/root-ca-key.pem" \
    "${DASHBOARD_CERTS}/key.pem"
fi

if [[ "$CONFIGURE_ONLY" == "true" ]]; then
  echo "Configuration prepared. Run ${ROOT}/setup.sh to deploy."
  exit 0
fi

CLUSTER_NAME="$(jq -r '.ClusterName' "$PARAMS_FILE")"
export CLUSTER_NAME

if [[ "$SKIP_INFRA" != "true" ]]; then
  echo "==> Deploying EKS, node groups, IRSA, EBS CSI, and LB controller"
  (
    cd "${ROOT}/infra"
    CREATE_TEST_VPC="$CDX_CREATE_TEST_VPC" \
      PARAMS_FILE=parameters.json \
      ./deploy.sh
  )
fi

if [[ "$SKIP_WAZUH" == "true" ]]; then
  echo "Infrastructure complete; Wazuh apply skipped."
  exit 0
fi

FORWARD_PORT="${CDX_FORWARD_PORT:-514}"
if [[ -z "$FORWARD_TARGET" && "$NON_INTERACTIVE" != "true" ]]; then
  if confirm "Enable archive forwarding?" n; then
    ask FORWARD_TARGET "Syslog destination" ""
    ask FORWARD_PORT "Syslog UDP port" "514"
  fi
fi

APPLY_ARGS=(--image-registry "$IMAGE_REGISTRY" --image-tag "$IMAGE_TAG")
if [[ -n "$FORWARD_TARGET" ]]; then
  APPLY_ARGS=(
    --forward
    --target "$FORWARD_TARGET"
    --port "$FORWARD_PORT"
    "${APPLY_ARGS[@]}"
  )
fi

echo "==> Applying Wazuh ${IMAGE_TAG}"
(
  cd "${ROOT}/wazuh"
  ./apply.sh "${APPLY_ARGS[@]}"
)

if [[ -n "$FORWARD_TARGET" ]]; then
  kubectl -n wazuh rollout restart statefulset/wazuh-manager-worker
fi

echo "==> Waiting for workloads"
kubectl -n wazuh rollout status statefulset/wazuh-indexer --timeout=20m
kubectl -n wazuh rollout status statefulset/wazuh-manager-master --timeout=15m
kubectl -n wazuh rollout status statefulset/wazuh-manager-worker --timeout=15m
kubectl -n wazuh rollout status deployment/wazuh-dashboard --timeout=15m

echo
echo "Wazuh deployment complete."
kubectl -n wazuh get pods
kubectl -n wazuh get service wazuh wazuh-workers dashboard indexer
echo
echo "Important: rotate the placeholder Wazuh, indexer, and dashboard"
echo "credentials documented in README.md before production exposure."
