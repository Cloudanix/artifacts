#!/usr/bin/env bash
#
# Wazuh central server on EKS - infrastructure deploy.
#
# Orchestrates three CloudFormation stacks (EKS -> node groups -> IRSA), tags the
# customer subnets for AWS Load Balancer Controller discovery, installs the EBS
# CSI driver and the AWS Load Balancer Controller, and writes kubeconfig.
#
# Idempotent: re-running deploys updates in place and resumes.
# Ownership tags (aws-apn-id, Created_by, Environment, purpose) live in
# common-tags.sh and are applied to CFN stacks, VPC/subnets, and NLBs.
#
# Usage:
#   export AWS_REGION=us-east-1          # required
#   export AWS_PROFILE=customer-profile  # optional
#   cp parameters.example.json parameters.json && edit it
#   ./deploy.sh
#
# Env vars:
#   AWS_REGION   (required) target region
#   PARAMS_FILE  (default: parameters.json)
#   HELM         (default: helm)  - needed for the AWS LB Controller chart
set -o errexit -o nounset -o pipefail

: "${AWS_REGION:?Set AWS_REGION to the target region}"
PARAMS_FILE="${PARAMS_FILE:-parameters.json}"
HELM="${HELM:-helm}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$HERE/$PARAMS_FILE" ]] || { echo "Missing $PARAMS_FILE (copy parameters.example.json)"; exit 1; }

# --- read parameters.json (uses jq) ---
p() { jq -r ".$1" "$HERE/$PARAMS_FILE"; }
CLUSTER_NAME="$(p ClusterName)"
K8S_VERSION="$(p KubernetesVersion)"
VPC_ID="$(p VpcId)"
PRIVATE_SUBNETS="$(p PrivateSubnetIds)"
PUBLIC_SUBNETS="$(p PublicSubnetIds)"
GENERAL_TYPE="$(p GeneralInstanceType)"
GENERAL_DESIRED="$(p GeneralDesiredSize)"
WORKER_TYPE="$(p WorkerInstanceType)"
WORKER_DESIRED="$(p WorkerDesiredSize)"
SECRET_NAME="$(p SecretName)"
SECRET_VALUE="$(p SecretValue)"
WAZUH_NAMESPACE="wazuh"
WAZUH_SA="wazuh-manager"

# EKS rejects minSize > desiredSize. Template defaults Min=3 for general-ng;
# parameters.json often sets Desired=2. Clamp min to desired; max at least desired.
at_least() { if [[ "$1" -gt "$2" ]]; then echo "$1"; else echo "$2"; fi; }
GENERAL_MIN="${GENERAL_MIN:-$GENERAL_DESIRED}"
WORKER_MIN="${WORKER_MIN:-$WORKER_DESIRED}"
GENERAL_MAX="${GENERAL_MAX:-$(at_least "$GENERAL_DESIRED" 5)}"
WORKER_MAX="${WORKER_MAX:-$(at_least "$WORKER_DESIRED" 4)}"

AWS=(aws --region "$AWS_REGION")
# shellcheck source=common-tags.sh
source "$HERE/common-tags.sh"
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
echo "Account: $ACCOUNT_ID  Region: $AWS_REGION  Cluster: $CLUSTER_NAME"

deploy_stack() {
  local name="$1" template="$2"; shift 2
  echo "==> CloudFormation: $name"
  "${AWS[@]}" cloudformation deploy \
    --stack-name "$name" \
    --template-file "$HERE/$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --tags "${CFN_TAGS[@]}" \
    --parameter-overrides "$@"
}

# ============================================================
# Stack 0 (optional): test VPC. Enable with CREATE_TEST_VPC=true.
# Creates a VPC with 2 private + 2 public subnets (both spanning 2 AZs) and
# overrides VpcId / PrivateSubnetIds / PublicSubnetIds from parameters.json.
# Two public subnets are required so the internet-facing NLB enables both AZs
# (otherwise workers in the other AZ stay "unused" and 1514 times out).
# For production leave this off and supply the customer's real subnets.
# ============================================================
if [[ "${CREATE_TEST_VPC:-false}" == "true" ]]; then
  deploy_stack "${CLUSTER_NAME}-test-vpc" 00-test-vpc.yaml
  tv() { "${AWS[@]}" cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-test-vpc" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
  VPC_ID="$(tv VpcId)"
  PRIVATE_SUBNETS="$(tv PrivateSubnet1Id),$(tv PrivateSubnet2Id)"
  # Prefer dual-AZ public outputs (PublicSubnet1Id/2Id). Fall back to legacy
  # single PublicSubnetId if an older test-vpc stack is still deployed.
  PUB1="$(tv PublicSubnet1Id)"
  PUB2="$(tv PublicSubnet2Id)"
  if [[ -n "$PUB1" && "$PUB1" != "None" && -n "$PUB2" && "$PUB2" != "None" ]]; then
    PUBLIC_SUBNETS="${PUB1},${PUB2}"
  else
    PUBLIC_SUBNETS="$(tv PublicSubnetId)"
  fi
  echo "Test VPC: $VPC_ID  private=[$PRIVATE_SUBNETS]  public=[$PUBLIC_SUBNETS]"
fi

# ============================================================
# Stack 1: EKS cluster + OIDC
# ============================================================
deploy_stack "${CLUSTER_NAME}-eks" 01-eks.yaml \
  "ClusterName=${CLUSTER_NAME}" \
  "KubernetesVersion=${K8S_VERSION}" \
  "VpcId=${VPC_ID}" \
  "PrivateSubnetIds=${PRIVATE_SUBNETS}" \
  "PublicSubnetIds=${PUBLIC_SUBNETS}"

# Pull OIDC issuer for the IRSA trust policies (strip the https:// scheme).
OIDC_URL="$("${AWS[@]}" eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.identity.oidc.issuer' --output text)"
OIDC_HOST="${OIDC_URL#https://}"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
echo "OIDC host: $OIDC_HOST"

# ============================================================
# Stack 2: node groups
# ============================================================
deploy_stack "${CLUSTER_NAME}-nodegroups" 02-nodegroups.yaml \
  "ClusterName=${CLUSTER_NAME}" \
  "PrivateSubnetIds=${PRIVATE_SUBNETS}" \
  "GeneralInstanceType=${GENERAL_TYPE}" \
  "GeneralDesiredSize=${GENERAL_DESIRED}" \
  "GeneralMinSize=${GENERAL_MIN}" \
  "GeneralMaxSize=${GENERAL_MAX}" \
  "WorkerInstanceType=${WORKER_TYPE}" \
  "WorkerDesiredSize=${WORKER_DESIRED}" \
  "WorkerMinSize=${WORKER_MIN}" \
  "WorkerMaxSize=${WORKER_MAX}"

# ============================================================
# Stack 3: IRSA roles (LB Controller + EBS CSI)
# ============================================================
deploy_stack "${CLUSTER_NAME}-irsa" 03-irsa.yaml \
  "ClusterName=${CLUSTER_NAME}" \
  "OidcProviderArn=${OIDC_ARN}" \
  "OidcProviderHost=${OIDC_HOST}" \
  "SecretName=${SECRET_NAME}" \
  "SecretValue=${SECRET_VALUE}" \
  "WazuhNamespace=${WAZUH_NAMESPACE}" \
  "WazuhServiceAccount=${WAZUH_SA}"

out() { "${AWS[@]}" cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-irsa" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
LB_ROLE_ARN="$(out LBControllerRoleArn)"
EBS_ROLE_ARN="$(out EbsCsiRoleArn)"
WAZUH_ROLE_ARN="$(out WazuhManagerRoleArn)"
SECRET_ARN="$(out SecretArn)"

# ============================================================
# kubeconfig
# ============================================================
echo "==> Updating kubeconfig"
"${AWS[@]}" eks update-kubeconfig --name "$CLUSTER_NAME"

# ============================================================
# Subnet tagging for AWS Load Balancer Controller auto-discovery
#   public  -> kubernetes.io/role/elb=1            (internet-facing LBs)
#   private -> kubernetes.io/role/internal-elb=1   (internal LBs)
#   all     -> kubernetes.io/cluster/<name>=shared
# ============================================================
echo "==> Tagging VPC + subnets (LB discovery + ownership)"
tag_ec2 "$VPC_ID"
IFS=',' read -ra PUB <<< "$PUBLIC_SUBNETS"
IFS=',' read -ra PRIV <<< "$PRIVATE_SUBNETS"
for s in "${PUB[@]}"; do
  "${AWS[@]}" ec2 create-tags --resources "$s" --tags \
    "${EC2_TAGS[@]}" \
    "Key=kubernetes.io/role/elb,Value=1" \
    "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
done
for s in "${PRIV[@]}"; do
  "${AWS[@]}" ec2 create-tags --resources "$s" --tags \
    "${EC2_TAGS[@]}" \
    "Key=kubernetes.io/role/internal-elb,Value=1" \
    "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
done

# ============================================================
# EBS CSI driver (managed addon) with IRSA
# ============================================================
echo "==> Installing EBS CSI driver addon"
"${AWS[@]}" eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "$EBS_ROLE_ARN" \
  --resolve-conflicts OVERWRITE 2>/dev/null \
  || "${AWS[@]}" eks update-addon \
       --cluster-name "$CLUSTER_NAME" \
       --addon-name aws-ebs-csi-driver \
       --service-account-role-arn "$EBS_ROLE_ARN" \
       --resolve-conflicts OVERWRITE

# ============================================================
# AWS Load Balancer Controller (Helm) with IRSA service account
# ============================================================
echo "==> Installing AWS Load Balancer Controller"
kubectl create serviceaccount aws-load-balancer-controller -n kube-system \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  "eks.amazonaws.com/role-arn=${LB_ROLE_ARN}" --overwrite

"$HELM" repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
"$HELM" repo update >/dev/null
HELM_TAG_SETS=()
for t in "${CFN_TAGS[@]}"; do
  HELM_TAG_SETS+=(--set-string "defaultTags.${t%%=*}=${t#*=}")
done
"$HELM" upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  "${HELM_TAG_SETS[@]}"

# ============================================================
# Wazuh manager IRSA ServiceAccount (reads the cloudanix secret)
# Pre-create the namespace + annotated SA so the kustomize apply adopts it.
# The role ARN contains the account ID, so it is injected here at deploy time
# rather than hardcoded in the overlay.
# ============================================================
echo "==> Creating wazuh-manager ServiceAccount with IRSA annotation"
kubectl create namespace "$WAZUH_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "$WAZUH_SA" -n "$WAZUH_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "$WAZUH_SA" -n "$WAZUH_NAMESPACE" \
  "eks.amazonaws.com/role-arn=${WAZUH_ROLE_ARN}" --overwrite

echo ""
echo "=========================================================="
echo " Infra ready."
echo "   Secret:            ${SECRET_NAME}"
echo "   Secret ARN:        ${SECRET_ARN}"
echo "   Wazuh IRSA role:   ${WAZUH_ROLE_ARN}"
echo ""
echo " Next:"
echo "   cd ../wazuh && kubectl apply -k envs/aws-customer"
echo ""
echo " Update the secret later with:"
echo "   aws secretsmanager put-secret-value --secret-id ${SECRET_NAME} \\"
echo "     --secret-string '{\"workspace_id\":\"token\"}' --region ${AWS_REGION}"
echo "=========================================================="
