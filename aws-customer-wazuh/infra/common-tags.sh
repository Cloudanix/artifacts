# Shared cost/ownership tags for every AWS resource this playbook creates.
# Sourced by deploy.sh and create-vpc.sh. Do not execute this file.
#
#   aws-apn-id   AWS Partner Network id
#   Created_by   Cloudanix
#   Environment  Prod
#   purpose      wazuh_vm_scan

# cloudformation deploy --tags Key=Value
CFN_TAGS=(
  "aws-apn-id=pc:2k1o8bijfwf7aykfulhgkc2uo"
  "Created_by=Cloudanix"
  "Environment=Prod"
  "purpose=wazuh_vm_scan"
)

# ec2 create-tags --tags Key=...,Value=...
EC2_TAGS=(
  "Key=aws-apn-id,Value=pc:2k1o8bijfwf7aykfulhgkc2uo"
  "Key=Created_by,Value=Cloudanix"
  "Key=Environment,Value=Prod"
  "Key=purpose,Value=wazuh_vm_scan"
)

tag_ec2() {
  [[ $# -eq 0 ]] && return 0
  "${AWS[@]}" ec2 create-tags --resources "$@" --tags "${EC2_TAGS[@]}"
}
