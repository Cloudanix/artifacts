#!/usr/bin/env bash
#
# Wazuh central server on EKS - S3 raw-archive destination.
#
# Creates the S3 bucket the Wazuh workers upload raw archive events to, and
# grants the existing wazuh-manager IRSA role write access to it. This is the
# AWS half of the archive-to-S3 path; the in-cluster half is applied with
#   ../wazuh/apply.sh --s3 --bucket <name>
#
# The bucket is private, encrypted, TLS-only and lifecycled. Objects land as
#   s3://<bucket>/<prefix>/<pod>/<YYYY-MM-DD>/<HH>/<MM>.json
# one raw Wazuh event per line (NDJSON).
#
# Idempotent: safe to re-run. Existing bucket/policy are updated in place.
#
# Usage:
#   export AWS_REGION=ap-south-1          # required
#   export AWS_PROFILE=customer-profile   # optional
#   ./setup-s3-archive.sh --bucket cdx-wazuh-archives-529819913013
#
# Options:
#   --bucket NAME        (required) S3 bucket to create or reuse
#   --prefix P           Key prefix inside the bucket (default: wazuh-archives)
#   --cluster-name N     Cluster/stack prefix, matches parameters.json (default: wazuh)
#   --retention-days N   Expire archived objects after N days (default: 90)
#   --dry-run            Print the AWS calls without making changes
#
# Env vars:
#   AWS_REGION   (required) target region
#   AWS_PROFILE  (optional) named profile
set -o errexit -o nounset -o pipefail

: "${AWS_REGION:?Set AWS_REGION to the target region}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUCKET=""
PREFIX="wazuh-archives"
CLUSTER_NAME="wazuh"
RETENTION_DAYS=90
DRY_RUN=0

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)         BUCKET="${2:?--bucket requires a name}"; shift 2 ;;
    --prefix)         PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
    --cluster-name)   CLUSTER_NAME="${2:?--cluster-name requires a value}"; shift 2 ;;
    --retention-days) RETENTION_DAYS="${2:?--retention-days requires a number}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$BUCKET" ]] || { echo "error: --bucket is required" >&2; exit 1; }
PREFIX="${PREFIX%/}"

AWS=(aws --region "$AWS_REGION")
# shellcheck source=common-tags.sh
source "$HERE/common-tags.sh"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
ROLE_NAME="${CLUSTER_NAME}-wazuh-manager-role"
POLICY_NAME="${CLUSTER_NAME}-wazuh-s3-archive-policy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "Account: $ACCOUNT_ID  Region: $AWS_REGION"
echo "Bucket:  s3://${BUCKET}/${PREFIX}/"
echo "Role:    $ROLE_NAME"
echo

# --- bucket ------------------------------------------------------------------
# create-bucket rejects LocationConstraint in us-east-1 and requires it everywhere else.
if "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket $BUCKET already exists, reusing"
else
  echo "==> Creating bucket $BUCKET"
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    run "${AWS[@]}" s3api create-bucket --bucket "$BUCKET"
  else
    run "${AWS[@]}" s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
fi

echo "==> Blocking all public access"
run "${AWS[@]}" s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "==> Enabling default encryption (SSE-S3) and bucket keys"
run "${AWS[@]}" s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo "==> Enabling versioning"
run "${AWS[@]}" s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration 'Status=Enabled'

echo "==> Lifecycle: expire objects after ${RETENTION_DAYS}d"
run "${AWS[@]}" s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "{
    \"Rules\": [{
      \"ID\": \"wazuh-archive-retention\",
      \"Status\": \"Enabled\",
      \"Filter\": {\"Prefix\": \"${PREFIX}/\"},
      \"Expiration\": {\"Days\": ${RETENTION_DAYS}},
      \"NoncurrentVersionExpiration\": {\"NoncurrentDays\": 7},
      \"AbortIncompleteMultipartUpload\": {\"DaysAfterInitiation\": 7}
    }]
  }"

# Cloudanix CSPM (and most benchmarks) flag buckets that accept plaintext HTTP.
echo "==> Bucket policy: deny non-TLS requests"
run "${AWS[@]}" s3api put-bucket-policy --bucket "$BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"DenyInsecureTransport\",
    \"Effect\": \"Deny\",
    \"Principal\": \"*\",
    \"Action\": \"s3:*\",
    \"Resource\": [
      \"arn:aws:s3:::${BUCKET}\",
      \"arn:aws:s3:::${BUCKET}/*\"
    ],
    \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
  }]
}"

echo "==> Tagging bucket"
TAG_SET="$(printf '%s\n' "${CFN_TAGS[@]}" | awk -F= '{printf "{\"Key\":\"%s\",\"Value\":\"%s\"},", $1, $2}' | sed 's/,$//')"
run "${AWS[@]}" s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging "{\"TagSet\":[${TAG_SET}]}"

# --- IAM ---------------------------------------------------------------------
# Scoped to this bucket and prefix only. ListBucket is needed so the uploader can
# verify a key landed; everything else stays denied.
POLICY_DOC="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Sid\": \"WriteArchives\",
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:PutObject\", \"s3:AbortMultipartUpload\"],
      \"Resource\": \"arn:aws:s3:::${BUCKET}/${PREFIX}/*\"
    },
    {
      \"Sid\": \"ListOwnPrefix\",
      \"Effect\": \"Allow\",
      \"Action\": \"s3:ListBucket\",
      \"Resource\": \"arn:aws:s3:::${BUCKET}\",
      \"Condition\": {\"StringLike\": {\"s3:prefix\": \"${PREFIX}/*\"}}
    }
  ]
}"

if "${AWS[@]}" iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "==> Updating managed policy $POLICY_NAME"
  # A managed policy keeps at most 5 versions; prune non-default ones first.
  for v in $("${AWS[@]}" iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    run "${AWS[@]}" iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  run "${AWS[@]}" iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "$POLICY_DOC" --set-as-default
else
  echo "==> Creating managed policy $POLICY_NAME"
  run "${AWS[@]}" iam create-policy --policy-name "$POLICY_NAME" \
    --description "Wazuh workers write raw archive events to s3://${BUCKET}/${PREFIX}/" \
    --policy-document "$POLICY_DOC" \
    --tags "${EC2_TAGS[@]}"
fi

echo "==> Attaching $POLICY_NAME to $ROLE_NAME"
if ! "${AWS[@]}" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "error: role $ROLE_NAME not found. Run ./deploy.sh first (stack ${CLUSTER_NAME}-irsa)." >&2
  exit 1
fi
run "${AWS[@]}" iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"

cat <<EOF

S3 archive destination ready.

  Bucket    s3://${BUCKET}/${PREFIX}/
  Retention ${RETENTION_DAYS} days
  Role      ${ROLE_NAME} (+ ${POLICY_NAME})

Next, enable the in-cluster half:

  cd ../wazuh
  ./apply.sh --s3 --bucket ${BUCKET} --s3-prefix ${PREFIX}
  kubectl rollout restart statefulset/wazuh-manager-worker -n wazuh

Then verify (allow ~3 minutes for the first object):

  aws s3 ls s3://${BUCKET}/${PREFIX}/ --recursive --region ${AWS_REGION} | tail
EOF
