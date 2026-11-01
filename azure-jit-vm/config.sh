#!/usr/bin/env bash
# =============================================================================
# Azure JIT VM — Configuration Schema
# =============================================================================
# Non-secret inputs only. These are saved to .state.json.
# CDX_AUTH_TOKEN and CDX_SIGNATURE_SECRET_KEY are never saved: export them in
# the shell before a hub install. Step 04 reads them from the environment.
# =============================================================================

SETUP_TYPE="azure-jit-vm"
SETUP_DISPLAY_NAME="Azure JIT VM"

# =============================================================================
# SCOPE MODES
# =============================================================================

SCOPE_MODES=("new-vnet" "existing-vnet" "onboard-peered" "onboard-new-vnet")
SCOPE_MODE_LABELS=(
    "New VNet (hub VNet, jump VM, private proxy, peer to the target VNet)"
    "Existing VNet (proxy in a VNet you already have)"
    "Onboard VM in an already-peered VNet (reuse the hub)"
    "Onboard VM in a new VNet (reuse the hub, create peering)"
)

# =============================================================================
# STEPS PER SCOPE MODE
# =============================================================================

declare -A STEPS_FOR_MODE
STEPS_FOR_MODE["new-vnet"]="00-create-roles 00-import-images 01-network-and-jump-vm 02-storage-and-keyvaults 03-identity-and-rbac 04-runtime-config 05-proxy-containers 06-jump-forwarders 07-peer-vnet 08-accept-peering 09-allow-target-ssh 10-store-ssh-key"
STEPS_FOR_MODE["existing-vnet"]="00-create-roles 00-import-images 01-existing-vnet 02-storage-and-keyvaults 03-identity-and-rbac 04-runtime-config 05-proxy-containers 06-jump-forwarders 09-allow-target-ssh 10-store-ssh-key"
STEPS_FOR_MODE["onboard-peered"]="09-allow-target-ssh 10-store-ssh-key"
STEPS_FOR_MODE["onboard-new-vnet"]="07-peer-vnet 08-accept-peering 09-allow-target-ssh 10-store-ssh-key"

# =============================================================================
# ACCOUNT CONTEXT PER STEP
# =============================================================================

declare -A STEP_ACCOUNT
STEP_ACCOUNT["00-create-roles"]="azure-subscription"
STEP_ACCOUNT["00-import-images"]="azure-subscription"
STEP_ACCOUNT["01-network-and-jump-vm"]="azure-subscription"
STEP_ACCOUNT["01-existing-vnet"]="azure-subscription"
STEP_ACCOUNT["02-storage-and-keyvaults"]="azure-subscription"
STEP_ACCOUNT["03-identity-and-rbac"]="azure-subscription"
STEP_ACCOUNT["04-runtime-config"]="azure-subscription"
STEP_ACCOUNT["05-proxy-containers"]="azure-subscription"
STEP_ACCOUNT["06-jump-forwarders"]="azure-subscription"
STEP_ACCOUNT["07-peer-vnet"]="azure-subscription"
STEP_ACCOUNT["08-accept-peering"]="target-subscription"
STEP_ACCOUNT["09-allow-target-ssh"]="target-subscription"
STEP_ACCOUNT["10-store-ssh-key"]="azure-subscription"

# =============================================================================
# STEP DISPLAY LABELS
# =============================================================================

declare -A STEP_LABELS
STEP_LABELS["00-create-roles"]="JIT VM custom roles"
STEP_LABELS["00-import-images"]="Import proxy images from the Cloudanix registry"
STEP_LABELS["01-network-and-jump-vm"]="Network and Jump VM (Entra SSH login)"
STEP_LABELS["01-existing-vnet"]="Jump VM in an existing VNet"
STEP_LABELS["02-storage-and-keyvaults"]="Storage Account and Key Vaults"
STEP_LABELS["03-identity-and-rbac"]="Managed Identity and Role Assignments"
STEP_LABELS["04-runtime-config"]="Runtime configuration"
STEP_LABELS["05-proxy-containers"]="Private Proxy Containers (sshpiper, VM proxy, logging)"
STEP_LABELS["06-jump-forwarders"]="Jump VM Loopback Forwarders"
STEP_LABELS["07-peer-vnet"]="Peer hub VNet to the target VNet"
STEP_LABELS["08-accept-peering"]="Accept peering from the target VNet"
STEP_LABELS["09-allow-target-ssh"]="Allow proxy subnet to SSH to the target"
STEP_LABELS["10-store-ssh-key"]="Store the target SSH key"

# =============================================================================
# ACCOUNT LABELS
# =============================================================================

declare -A ACCOUNT_LABELS
ACCOUNT_LABELS["azure-subscription"]="Hub Azure Subscription"
ACCOUNT_LABELS["target-subscription"]="Target VM Subscription"

declare -A ACCOUNT_ID_FIELD
ACCOUNT_ID_FIELD["azure-subscription"]="SUBSCRIPTION_ID"
ACCOUNT_ID_FIELD["target-subscription"]="TARGET_SUBSCRIPTION_ID"

# =============================================================================
# CONFIGURATION FIELDS
# =============================================================================
# Format: NAME|RULE|DEFAULT|PROMPT|SCOPES|SENSITIVE

CONFIG_FIELDS=(
    "SUBSCRIPTION_ID|azure_subscription_id||Hub Azure Subscription ID|*|false"
    "TARGET_SUBSCRIPTION_ID|azure_subscription_id||Target VM Subscription ID (same GUID if one subscription)|new-vnet,onboard-new-vnet,onboard-peered|false"
    "LOCATION|nonempty|eastus2|Azure Region|new-vnet,existing-vnet|false"
    "NAME_PREFIX|alphanumeric_dash|cdxjit|Resource name prefix (3-12 lowercase letters/digits, must match the hub you are reusing)|*|false"
    "SSH_ALLOWED_CIDRS|nonempty||Operator IP CIDR(s) allowed to SSH the jump VM (comma-separated, not 0.0.0.0/0)|new-vnet,existing-vnet|false"
    "OPERATOR_OBJECT_ID|nonempty||Entra object ID of the operator who runs az ssh|new-vnet,existing-vnet|false"
    "JUMP_VM_ADMIN_USERNAME|alphanumeric_dash|azureuser|Jump VM admin username|new-vnet,existing-vnet|false"
    "JUMP_VM_SSH_PUBLIC_KEY_FILE|nonempty|${HOME}/.ssh/id_ed25519.pub|Jump VM break-glass SSH public key file|new-vnet,existing-vnet|false"
    "EXISTING_VNET_NAME|nonempty||Existing VNet name|existing-vnet|false"
    "EXISTING_VNET_RG|nonempty||Resource group of that VNet|existing-vnet|false"
    "EXISTING_JUMP_SUBNET|nonempty||Existing subnet for the jump VM|existing-vnet|false"
    "EXISTING_ACI_SUBNET|nonempty||Existing subnet for the proxy containers (delegated to Container Instances, or empty so this script can delegate it)|existing-vnet|false"
    "IMAGE_REGISTRY|nonempty||Registry login server holding the proxy images (e.g. example.azurecr.io)|new-vnet,existing-vnet|false"
    "ACR_RESOURCE_ID|nonempty||Resource ID of that registry (receives AcrPull)|new-vnet,existing-vnet|false"
    "IMAGE_TAG|image_tag||Image tag to pull and deploy (for example v0.3.33, not latest)|new-vnet,existing-vnet|false"
    "SSHPIPER_IMAGE|nonempty|cloudanix/ecr-aws-jit-vm-sshpiper|sshpiper image path in the registry|new-vnet,existing-vnet|false"
    "VMPROXY_IMAGE|nonempty|cloudanix/ecr-aws-jit-vm-proxyserver|VM proxy server image path in the registry|new-vnet,existing-vnet|false"
    "LOGGING_IMAGE|nonempty|cloudanix/ecr-aws-jit-vm-logging|Command logging image path in the registry|new-vnet,existing-vnet|false"
    "CDX_API_BASE|nonempty|https://api.cloudanix.com|Cloudanix API base URL|new-vnet,existing-vnet|false"
    "CDX_DC|nonempty|US|Cloudanix data center (US, IN, or MC1)|new-vnet,existing-vnet|false"
    "LOG_CONTAINER|alphanumeric_dash|jit-vm-logs|Blob container for session recordings|new-vnet,existing-vnet|false"
    "TARGET_VNET_NAME|nonempty||Target VNet name|new-vnet,onboard-new-vnet|false"
    "TARGET_VNET_RG|nonempty||Resource group of the target VNet|new-vnet,onboard-new-vnet|false"
    "TARGET_VM_NAME|nonempty||Target VM name|*|false"
    "TARGET_VM_RG|nonempty||Resource group of the target VM|*|false"
    "TARGET_VM_OS_USER|nonempty|azureuser|OS user on the target VM|*|false"
    "TARGET_SSH_PRIVATE_KEY_FILE|nonempty||Path to that VM's SSH private key|*|false"
)

# =============================================================================
# PREREQUISITES
# =============================================================================

PREREQUISITES=("az" "jq")
