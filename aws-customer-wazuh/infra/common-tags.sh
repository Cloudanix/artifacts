# Shared cost/ownership tags for every AWS resource this playbook creates.
# Sourced by deploy.sh and create-vpc.sh. Do not execute this file.
#
#   aws-apn-id     AWS Partner Network id
#   asset-owner    Cloudanix
#   asset-service  CloudSecurity
#   asset-purpose  Security-Monitoring

# cloudformation deploy --tags Key=Value
CFN_TAGS=(
  "aws-apn-id=pc:2k1o8bijfwf7aykfulhgkc2uo"
  "asset-owner=Cloudanix"
  "asset-service=CloudSecurity"
  "asset-purpose=Security-Monitoring"
)

# ec2 create-tags --tags Key=...,Value=...
EC2_TAGS=(
  "Key=aws-apn-id,Value=pc:2k1o8bijfwf7aykfulhgkc2uo"
  "Key=asset-owner,Value=Cloudanix"
  "Key=asset-service,Value=CloudSecurity"
  "Key=asset-purpose,Value=Security-Monitoring"
)

tag_ec2() {
  [[ $# -eq 0 ]] && return 0
  "${AWS[@]}" ec2 create-tags --resources "$@" --tags "${EC2_TAGS[@]}"
}
