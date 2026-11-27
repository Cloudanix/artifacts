#!/usr/bin/env bash
# Apply AWS-customer Wazuh overlay; optional archive syslog forwarding.

set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OVERLAY="${ROOT}/envs/aws-customer"
FORWARD_OVERLAY="${ROOT}/envs/aws-customer-forward"
TEMPLATE_CONF="${FORWARD_OVERLAY}/60-wazuh-archives.conf"
WORKER_CONF_SRC="${ROOT}/base/wazuh_managers/wazuh_conf/worker.conf"

MASTER_IMAGE="public.ecr.aws/cloudanix/wazuh-master-custom"
WORKER_IMAGE="public.ecr.aws/cloudanix/wazuh-worker-custom"

FORWARD=0
DRY_RUN=0
SKIP_SA=0
CLUSTER_NAME="${CLUSTER_NAME:-wazuh}"
NAMESPACE="${NAMESPACE:-wazuh}"
WAZUH_SA="${WAZUH_SA:-wazuh-manager}"
TARGET_IP="${TARGET_IP:-}"
FORWARD_PORT="${FORWARD_PORT:-514}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
MASTER_TAG="${MASTER_TAG:-}"
WORKER_TAG="${WORKER_TAG:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Apply the default overlay (envs/aws-customer), or the forwarding overlay.

Options:
  --forward              Apply envs/aws-customer-forward (archive syslog)
  --target IP            Forward destination (required with --forward)
  --port N               Forward port (default: 514)
  --image-registry R     Registry prefix for master/worker images
  --image-tag TAG        Tag for both images
  --master-tag TAG       Tag for wazuh-master-custom
  --worker-tag TAG       Tag for wazuh-worker-custom
  --dry-run              kubectl apply --dry-run=client
  --skip-sa              Do not create/annotate the wazuh-manager ServiceAccount
  -h, --help             Show this help

Params file (optional): ${FORWARD_OVERLAY}/forward.params
Flags override sourced values.
EOF
}

PARAMS_FILE="${FORWARD_OVERLAY}/forward.params"
if [[ -f "${PARAMS_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${PARAMS_FILE}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forward)
      FORWARD=1
      shift
      ;;
    --target)
      TARGET_IP="${2:?--target requires an IP or hostname}"
      shift 2
      ;;
    --port)
      FORWARD_PORT="${2:?--port requires a port number}"
      shift 2
      ;;
    --image-registry)
      IMAGE_REGISTRY="${2:?--image-registry requires a registry}"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="${2:?--image-tag requires a tag}"
      shift 2
      ;;
    --master-tag)
      MASTER_TAG="${2:?--master-tag requires a tag}"
      shift 2
      ;;
    --worker-tag)
      WORKER_TAG="${2:?--worker-tag requires a tag}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-sa)
      SKIP_SA=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

FORWARD_PORT="${FORWARD_PORT:-514}"

if [[ "${FORWARD}" -eq 1 && -z "${TARGET_IP:-}" ]]; then
  echo "error: --forward requires --target or TARGET_IP" >&2
  exit 1
fi

image_spec() {
  local src_name="$1"
  local short_name="$2"
  local tag="$3"
  if [[ -n "${IMAGE_REGISTRY}" ]]; then
    local spec="${src_name}=${IMAGE_REGISTRY}/${short_name}"
    if [[ -n "${tag}" ]]; then
      spec="${spec}:${tag}"
    fi
    printf "%s\n" "${spec}"
  elif [[ -n "${tag}" ]]; then
    printf "%s\n" "${src_name}:${tag}"
  fi
}

patch_kustomize_images() {
  local kust="$1"
  local registry="$2"
  local master_tag="$3"
  local worker_tag="$4"
  python3 - "$kust" "$registry" "$master_tag" "$worker_tag" <<'PY'
import sys
from pathlib import Path

path, registry, master_tag, worker_tag = sys.argv[1:5]
text = Path(path).read_text()
lines = text.splitlines(True)
out = []
i = 0
current = None
while i < len(lines):
    line = lines[i]
    if line.strip().startswith("- name: public.ecr.aws/cloudanix/wazuh-master-custom"):
        current = "master"
        out.append(line)
        i += 1
        continue
    if line.strip().startswith("- name: public.ecr.aws/cloudanix/wazuh-worker-custom"):
        current = "worker"
        out.append(line)
        i += 1
        continue
    if current and "newName:" in line and registry:
        indent = line[: len(line) - len(line.lstrip())]
        repo = "wazuh-master-custom" if current == "master" else "wazuh-worker-custom"
        out.append(f"{indent}newName: {registry}/{repo}\n")
        i += 1
        continue
    if current and "newTag:" in line:
        tag = master_tag if current == "master" else worker_tag
        if tag:
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}newTag: {tag}\n")
            current = None
            i += 1
            continue
        current = None
    out.append(line)
    i += 1
Path(path).write_text("".join(out))
PY
}

set_images() {
  local overlay="$1"
  local workdir dest master_tag worker_tag
  workdir="$(mktemp -d)"
  mkdir -p "${workdir}/envs"
  cp -a "${ROOT}/base" "${workdir}/base"
  cp -a "${DEFAULT_OVERLAY}" "${workdir}/envs/aws-customer"
  if [[ "${overlay}" == "${FORWARD_OVERLAY}" ]]; then
    cp -a "${FORWARD_OVERLAY}" "${workdir}/envs/aws-customer-forward"
  fi

  dest="${workdir}${overlay#"${ROOT}"}"
  master_tag="${MASTER_TAG:-${IMAGE_TAG:-}}"
  worker_tag="${WORKER_TAG:-${IMAGE_TAG:-}}"

  if [[ -n "${IMAGE_REGISTRY}" || -n "${master_tag}" || -n "${worker_tag}" ]]; then
    patch_kustomize_images \
      "${workdir}/envs/aws-customer/kustomization.yml" \
      "${IMAGE_REGISTRY}" \
      "${master_tag}" \
      "${worker_tag}"
  fi
  printf "%s\n" "${dest}"
}

generate_forward() {
  local gen="${FORWARD_OVERLAY}/generated"
  mkdir -p "${gen}"
  if [[ ! -f "${TEMPLATE_CONF}" ]]; then
    echo "error: missing template ${TEMPLATE_CONF}" >&2
    exit 1
  fi
  if [[ ! -f "${WORKER_CONF_SRC}" ]]; then
    echo "error: missing ${WORKER_CONF_SRC}" >&2
    exit 1
  fi
  sed -e "s|__FORWARD_TARGET__|${TARGET_IP}|g" \
      -e "s|__FORWARD_PORT__|${FORWARD_PORT}|g" \
      "${TEMPLATE_CONF}" > "${gen}/60-wazuh-archives.conf"
  sed -E "s/(<logall(_json)?>)no(<\/logall(_json)?>)/\1yes\3/g" \
      "${WORKER_CONF_SRC}" > "${gen}/worker.conf"
}

# The manager pods run under an IRSA ServiceAccount created by infra/deploy.sh.
# `kubectl delete namespace wazuh` takes it with the namespace, and kustomize
# does not own it, so the StatefulSets then fail with
# `serviceaccount "wazuh-manager" not found` and never create a pod.
# Recreate it here from the CloudFormation IRSA stack output.
ensure_service_account() {
  if [[ "${SKIP_SA}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local role_arn
  role_arn="$(aws cloudformation describe-stacks \
    --stack-name "${CLUSTER_NAME}-irsa" \
    --query 'Stacks[0].Outputs[?OutputKey==`WazuhManagerRoleArn`].OutputValue' \
    --output text 2>/dev/null || true)"

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create serviceaccount "${WAZUH_SA}" -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  if [[ -n "${role_arn}" && "${role_arn}" != "None" ]]; then
    kubectl annotate serviceaccount "${WAZUH_SA}" -n "${NAMESPACE}" \
      "eks.amazonaws.com/role-arn=${role_arn}" --overwrite
  else
    echo "warn: no WazuhManagerRoleArn from stack ${CLUSTER_NAME}-irsa;" >&2
    echo "      ${WAZUH_SA} has no IRSA annotation and cannot read the secret." >&2
  fi
}

run_apply() {
  local path="$1"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    kubectl apply --validate=false --dry-run=client -k "${path}"
  else
    kubectl apply --validate=false -k "${path}"
  fi
}

cleanup_apply_workdir() {
  local path="${APPLY_PATH:-}" workdir
  [[ -n "$path" ]] || return 0
  workdir="${path%%/envs/*}"
  [[ -n "$workdir" && "$workdir" != "$path" ]] && rm -r "$workdir"
}
trap cleanup_apply_workdir EXIT

ensure_service_account

if [[ "${FORWARD}" -eq 1 ]]; then
  generate_forward
  APPLY_PATH="$(set_images "${FORWARD_OVERLAY}")"
  run_apply "${APPLY_PATH}"
  echo
  echo "Workers will not pick up generated worker.conf / rsyslog drop-in until restarted:"
  echo "  kubectl rollout restart statefulset/wazuh-manager-worker -n wazuh"
else
  APPLY_PATH="$(set_images "${DEFAULT_OVERLAY}")"
  run_apply "${APPLY_PATH}"
fi
