#!/usr/bin/env bash
# Tear down Wazuh EKS QA infra so deploy.sh can recreate it from scratch.
#
# Order: in-cluster LBs/workloads -> helm -> CF stacks (reverse of deploy) ->
# leftover EBS (Retain PVs) -> Secrets Manager (force, so the same name can
# be recreated).
#
# Usage:
#   export AWS_REGION=us-east-1
#   ./cleanup.sh
#
# Env:
#   AWS_REGION     required
#   PARAMS_FILE    default parameters.json
#   SKIP_K8S       true to skip kubectl/helm (cluster already gone)
#   KEEP_SECRET    true to leave cdx-central-vm-auth-tokens in place
#   KEEP_EBS         true to leave leftover gp3 volumes
#   DELETE_TEST_VPC  true to also delete ${CLUSTER}-test-vpc (default: keep VPC)

set -o errexit -o nounset -o pipefail

: "${AWS_REGION:?Set AWS_REGION to the target region}"
PARAMS_FILE="${PARAMS_FILE:-parameters.json}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$HERE/$PARAMS_FILE" ]] || { echo "Missing $PARAMS_FILE"; exit 1; }

p() { jq -r ".$1" "$HERE/$PARAMS_FILE"; }
CLUSTER_NAME="$(p ClusterName)"
SECRET_NAME="$(p SecretName)"
AWS=(aws --region "$AWS_REGION")

ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
echo "Account: $ACCOUNT_ID  Region: $AWS_REGION  Cluster: $CLUSTER_NAME"

stack_exists() {
  local name="$1" status
  status="$("${AWS[@]}" cloudformation describe-stacks --stack-name "$name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
  [[ -n "$status" && "$status" != "None" && "$status" != "DELETE_COMPLETE" ]]
}

delete_stack() {
  local name="$1"
  if ! stack_exists "$name"; then
    echo "==> skip CF ${name} (not found)"
    return 0
  fi
  echo "==> CloudFormation delete ${name}"
  "${AWS[@]}" cloudformation delete-stack --stack-name "$name"
  "${AWS[@]}" cloudformation wait stack-delete-complete --stack-name "$name"
  echo "    ${name} deleted"
}

vpc_id_from_stack() {
  local name="$1" vpc
  vpc="$("${AWS[@]}" cloudformation describe-stack-resources --stack-name "$name" \
    --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' \
    --output text 2>/dev/null || true)"
  if [[ -z "$vpc" || "$vpc" == "None" ]]; then
    vpc="$("${AWS[@]}" cloudformation describe-stacks --stack-name "$name" \
      --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
      --output text 2>/dev/null || true)"
  fi
  printf '%s' "${vpc}"
}

# Extra subnet/gateway associations on a CF-owned route table are not in the
# stack (NLB, operator, etc.). CF then fails: routeTable has dependencies.
disassociate_route_tables() {
  local vpc="$1"
  local rtb assoc main
  while IFS= read -r rtb; do
    [[ -z "$rtb" || "$rtb" == "None" ]] && continue
    echo "    route table ${rtb}"
    while IFS=$'\t' read -r assoc main; do
      [[ -z "$assoc" || "$assoc" == "None" ]] && continue
      [[ "$main" == "True" || "$main" == "true" ]] && continue
      echo "    disassociate ${assoc}"
      "${AWS[@]}" ec2 disassociate-route-table --association-id "$assoc" || true
    done < <("${AWS[@]}" ec2 describe-route-tables --route-table-ids "$rtb" \
      --query 'RouteTables[0].Associations[].[RouteTableAssociationId,Main]' \
      --output text 2>/dev/null)
  done < <("${AWS[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc}" \
    --query 'RouteTables[].RouteTableId' --output text 2>/dev/null | tr '\t' '\n')
}

# EKS/NLB leftovers are not in the VPC stack; they pin subnets/SGs and
# make wazuh-test-vpc DELETE_FAILED. Strip them, then CF can finish.
scrub_vpc() {
  local vpc="$1"
  [[ -n "$vpc" && "$vpc" != "None" ]] || return 0
  echo "==> Scrub leftover AWS resources in ${vpc}"
  disassociate_route_tables "$vpc"

  local arn
  while IFS= read -r arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    echo "    delete LB ${arn}"
    "${AWS[@]}" elbv2 delete-load-balancer --load-balancer-arn "$arn" || true
  done < <("${AWS[@]}" elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='${vpc}'].LoadBalancerArn" --output text 2>/dev/null | tr '\t' '\n')

  local ep
  while IFS= read -r ep; do
    [[ -z "$ep" || "$ep" == "None" ]] && continue
    echo "    delete VPC endpoint ${ep}"
    "${AWS[@]}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ep" >/dev/null || true
  done < <("${AWS[@]}" ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${vpc}" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null | tr '\t' '\n')

  local i=0
  while [[ $i -lt 20 ]]; do
    local leftover=0
    local eni status desc att
    while IFS=$'\t' read -r eni status desc att; do
      [[ -z "$eni" || "$eni" == "None" ]] && continue
      # NAT / CF-owned interfaces: leave for the stack to delete.
      if [[ "$desc" == *"NAT Gateway"* ]]; then
        continue
      fi
      leftover=1
      echo "    ENI ${eni} status=${status} ${desc}"
      if [[ "$status" == "in-use" && -n "$att" && "$att" != "None" ]]; then
        "${AWS[@]}" ec2 detach-network-interface --attachment-id "$att" --force || true
        sleep 2
      fi
      "${AWS[@]}" ec2 delete-network-interface --network-interface-id "$eni" || true
    done < <("${AWS[@]}" ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${vpc}" \
      --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description,Attachment.AttachmentId]' \
      --output text 2>/dev/null)

    local sg
    while IFS= read -r sg; do
      [[ -z "$sg" || "$sg" == "None" ]] && continue
      echo "    delete SG ${sg}"
      "${AWS[@]}" ec2 delete-security-group --group-id "$sg" || true
    done < <("${AWS[@]}" ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc}" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | tr '\t' '\n')

    if [[ "$leftover" -eq 0 ]]; then
      break
    fi
    i=$((i + 1))
    sleep 5
  done
}

delete_vpc_stack() {
  local name="$1" vpc
  if ! stack_exists "$name"; then
    echo "==> skip CF ${name} (not found)"
    return 0
  fi
  vpc="$(vpc_id_from_stack "$name")"
  echo "==> VPC stack ${name} (${vpc:-unknown})"
  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    scrub_vpc "$vpc"
  fi
  echo "==> CloudFormation delete ${name}"
  "${AWS[@]}" cloudformation delete-stack --stack-name "$name" || true
  if "${AWS[@]}" cloudformation wait stack-delete-complete --stack-name "$name"; then
    echo "    ${name} deleted"
    return 0
  fi
  echo "==> ${name} DELETE_FAILED — scrub again and retry"
  vpc="$(vpc_id_from_stack "$name")"
  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    scrub_vpc "$vpc"
  fi
  "${AWS[@]}" cloudformation describe-stack-events --stack-name "$name" \
    --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceType,ResourceStatusReason]' \
    --output table || true
  "${AWS[@]}" cloudformation delete-stack --stack-name "$name" || true
  "${AWS[@]}" cloudformation wait stack-delete-complete --stack-name "$name"
  echo "    ${name} deleted"
}

# ---- in-cluster (NLBs must go before nodegroups/VPC or ENIs stick) ----
if [[ "${SKIP_K8S:-false}" != "true" ]]; then
  if kubectl cluster-info >/dev/null 2>&1; then
    echo "==> Deleting wazuh namespace / Services (NLBs)"
    kubectl delete namespace wazuh --wait=true --timeout=8m --ignore-not-found=true || true
    echo "==> Uninstalling AWS Load Balancer Controller"
    helm uninstall aws-load-balancer-controller -n kube-system --wait --timeout 5m 2>/dev/null || true
    echo "==> Waiting for leftover NLBs tagged to this cluster"
    for _ in $(seq 1 30); do
      lbs="$("${AWS[@]}" elbv2 describe-load-balancers --query \
        "LoadBalancers[?contains(LoadBalancerName, 'k8s-wazuh') || contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
        --output text 2>/dev/null || true)"
      # Narrow: only LBs whose tags mention this cluster.
      leftover=""
      for arn in $lbs; do
        tags="$("${AWS[@]}" elbv2 describe-tags --resource-arns "$arn" \
          --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' || Key=='kubernetes.io/cluster/${CLUSTER_NAME}'].Value" \
          --output text 2>/dev/null || true)"
        if [[ "$tags" == *"${CLUSTER_NAME}"* ]]; then
          leftover="${leftover} ${arn}"
        fi
      done
      leftover="${leftover## }"
      if [[ -z "$leftover" ]]; then
        break
      fi
      echo "    still draining NLBs..."
      sleep 10
    done
  else
    echo "==> kubectl not reachable; skipping in-cluster delete"
  fi
fi

# ---- CF reverse of deploy.sh: irsa -> nodegroups -> eks -> test-vpc ----
delete_stack "${CLUSTER_NAME}-irsa"
delete_stack "${CLUSTER_NAME}-nodegroups"
delete_stack "${CLUSTER_NAME}-eks"

if [[ "${DELETE_TEST_VPC:-false}" == "true" ]]; then
  delete_vpc_stack "${CLUSTER_NAME}-test-vpc"
else
  echo "==> keeping CF ${CLUSTER_NAME}-test-vpc (set DELETE_TEST_VPC=true to nuke it)"
fi

# Optional pull-through cache stack (not created by deploy.sh by default)
if stack_exists "${CLUSTER_NAME}-ecr-pull-through" 2>/dev/null; then
  delete_stack "${CLUSTER_NAME}-ecr-pull-through"
fi

# ---- leftover EBS from reclaimPolicy: Retain ----
if [[ "${KEEP_EBS:-false}" != "true" ]]; then
  echo "==> Deleting leftover EBS volumes tagged kubernetes.io/cluster/${CLUSTER_NAME}"
  vols="$("${AWS[@]}" ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
              "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text)"
  if [[ -z "$vols" ]]; then
    echo "    none"
  else
    for v in $vols; do
      echo "    delete ${v}"
      "${AWS[@]}" ec2 delete-volume --volume-id "$v"
    done
  fi
fi

# ---- secret must be force-deleted or CF cannot recreate the same name ----
if [[ "${KEEP_SECRET:-false}" != "true" && -n "$SECRET_NAME" && "$SECRET_NAME" != "null" ]]; then
  echo "==> Force-deleting Secrets Manager secret ${SECRET_NAME}"
  "${AWS[@]}" secretsmanager delete-secret \
    --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery >/dev/null 2>&1 || true
fi

echo ""
echo "=========================================================="
echo " Cleanup done. Recreate with:"
echo "   export AWS_REGION=${AWS_REGION}"
echo "   CREATE_TEST_VPC=true ./deploy.sh"
echo "=========================================================="
