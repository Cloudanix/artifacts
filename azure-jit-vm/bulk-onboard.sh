#!/usr/bin/env bash
# =============================================================================
# Azure JIT VM — Bulk onboard from CSV
# =============================================================================
# Onboards many target VMs against one finished hub. For each row:
#   1. Confirm the VM exists, and that its region matches the CSV when given
#   2. Peer hub <-> target VNet. Skipped when a peering to that VNet exists
#   3. Allow TCP 22 from the proxy subnet on the target NSG
#   4. Store the root and non-root private keys in {prefix}-jitkeys-kv as
#      <vmId>-<user> and <vm-name>-<user>
#
# Keys per row: root_key_path and nonroot_key_path in the CSV. A row value
# wins. When a row leaves them empty, --root-key and --nonroot-key apply.
#
# Idempotent. .bulk-onboard-progress.json records completed VMs, peerings and
# NSGs, so a re-run skips them. Key Vault writes overwrite the same names, so
# storing a key again is safe. The progress file holds no key material.
#
# Pre-flight runs before any Azure change: every row must have its fields, a
# valid subscription ID, and a key file that exists. One bad row stops the run.
#
# CSV header (names are case-insensitive, order is free):
#   subscription_id,vm_resource_group,vm_name,region,root_user,nonroot_user,
#   root_key_path,nonroot_key_path,vnet_name,vnet_resource_group
# Required: subscription_id, vm_resource_group, vm_name. Others are optional.
# Values cannot contain commas or quotes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
source "$LIB_DIR/common.sh"
source "$SCRIPT_DIR/config.sh"

STATE_FILE="$SCRIPT_DIR/.state.json"
PROGRESS_FILE="$SCRIPT_DIR/.bulk-onboard-progress.json"

CSV_PATH=""
ROOT_KEY=""
NONROOT_KEY=""
ROOT_USER_DEFAULT="root"
NONROOT_USER_DEFAULT="ubuntu"
DRY_RUN=false

usage() {
    cat <<EOF
Usage: ./bulk-onboard.sh --csv PATH [--root-key PATH] [--nonroot-key PATH] [options]

  --csv PATH              CSV of target VMs (required)
  --root-key PATH         Default root key for rows without root_key_path
  --nonroot-key PATH      Default non-root key for rows without nonroot_key_path
  --root-user NAME        Default root OS user when the row omits root_user (default: root)
  --nonroot-user NAME     Default non-root OS user when the row omits nonroot_user (default: ubuntu)
  --dry-run               Check everything and print the plan. Changes nothing.
  -h, --help              Show this help

Every row needs a root key and a non-root key, from its own columns or from the flags.

CSV header:
  subscription_id,vm_resource_group,vm_name,region,root_user,nonroot_user,root_key_path,nonroot_key_path,vnet_name,vnet_resource_group

Needs a finished hub install (.state.json with SUBSCRIPTION_ID and NAME_PREFIX).
EOF
}

expand_path() {
    printf '%s' "${1/#\~/$HOME}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv) CSV_PATH="${2:-}"; shift 2 ;;
        --root-key) ROOT_KEY="$(expand_path "${2:-}")"; shift 2 ;;
        --nonroot-key) NONROOT_KEY="$(expand_path "${2:-}")"; shift 2 ;;
        --root-user) ROOT_USER_DEFAULT="${2:-}"; shift 2 ;;
        --nonroot-user) NONROOT_USER_DEFAULT="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            error "Unknown argument: $1"
            usage >&2
            exit 1
            ;;
    esac
done

[[ -n "$CSV_PATH" && -f "$CSV_PATH" ]] || { error "--csv is required and must exist"; usage >&2; exit 1; }
[[ -z "$ROOT_KEY" || -f "$ROOT_KEY" ]] || { error "--root-key does not exist: $ROOT_KEY"; exit 1; }
[[ -z "$NONROOT_KEY" || -f "$NONROOT_KEY" ]] || { error "--nonroot-key does not exist: $NONROOT_KEY"; exit 1; }
[[ -f "$STATE_FILE" ]] || { error "No hub state at $STATE_FILE. Run a hub install first."; exit 1; }

check_prerequisites az jq || exit 1

# Load the hub config into the environment, then the shared helpers. The
# helpers derive resource names (RG, KV_KEYS, ...) from NAME_PREFIX at load.
while IFS='=' read -r key value; do
    export "$key=$value"
done < <(jq -r '.config | to_entries[] | "\(.key)=\(.value)"' "$STATE_FILE")
source "$SCRIPT_DIR/steps/_helpers.sh"

require_env SUBSCRIPTION_ID NAME_PREFIX || exit 1
[[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9]{2,11}$ ]] || {
    error "NAME_PREFIX in state is invalid: $NAME_PREFIX"
    exit 1
}

warn "The setup guide says not to use root as the JIT user. This mode stores a root"
warn "key because the fleet uses one. Keep root access to the named users in the CSV."

# -----------------------------------------------------------------------------
# Progress file. Keys include '/', so every lookup uses jq --arg, not paths.
# -----------------------------------------------------------------------------
if [[ ! -f "$PROGRESS_FILE" ]]; then
    printf '%s\n' '{"vms":{},"peerings":{},"nsgs":{}}' > "$PROGRESS_FILE"
fi

progress_vm_status() {
    jq -r --arg k "$1" '.vms[$k].status // ""' "$PROGRESS_FILE"
}

progress_mark_vm() {
    local key="$1" status="$2" vm_id="${3:-}" root_user="${4:-}" nonroot_user="${5:-}" tmp
    tmp="$(mktemp)"
    jq --arg k "$key" --arg s "$status" --arg id "$vm_id" \
        --arg ru "$root_user" --arg nu "$nonroot_user" '
        .vms[$k] = {
            status: $s,
            vm_id: (if $id == "" then (.vms[$k].vm_id // "") else $id end),
            root_user: (if $ru == "" then (.vms[$k].root_user // "") else $ru end),
            nonroot_user: (if $nu == "" then (.vms[$k].nonroot_user // "") else $nu end)
        }
    ' "$PROGRESS_FILE" > "$tmp" && mv "$tmp" "$PROGRESS_FILE"
}

progress_peering() {
    jq -r --arg k "$1" '.peerings[$k] // ""' "$PROGRESS_FILE"
}

progress_mark_peering() {
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$1" --arg v "$2" '.peerings[$k] = $v' "$PROGRESS_FILE" > "$tmp" && mv "$tmp" "$PROGRESS_FILE"
}

progress_nsg() {
    jq -r --arg k "$1" '.nsgs[$k] // ""' "$PROGRESS_FILE"
}

progress_mark_nsg() {
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$1" --arg v "$2" '.nsgs[$k] = $v' "$PROGRESS_FILE" > "$tmp" && mv "$tmp" "$PROGRESS_FILE"
}

# -----------------------------------------------------------------------------
# CSV reading. Read the whole file first so az calls cannot consume rows.
# -----------------------------------------------------------------------------
mapfile -t LINES < <(tr -d '\r' < "$CSV_PATH")
[[ ${#LINES[@]} -gt 1 ]] || { error "CSV has a header and no rows: $CSV_PATH"; exit 1; }

IFS=',' read -ra HEADERS <<< "${LINES[0]}"
declare -A COL
for i in "${!HEADERS[@]}"; do
    h="$(printf '%s' "${HEADERS[$i]}" | tr '[:upper:]' '[:lower:]' | tr -d ' \t')"
    COL["$h"]="$i"
done
for required in subscription_id vm_resource_group vm_name; do
    [[ -n "${COL[$required]:-}" ]] || {
        error "CSV is missing required column: $required"
        error "Header must include: subscription_id,vm_resource_group,vm_name"
        exit 1
    }
done

DATA_ROWS=()
for line in "${LINES[@]:1}"; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    DATA_ROWS+=("$line")
done
[[ ${#DATA_ROWS[@]} -gt 0 ]] || { error "CSV has no data rows"; exit 1; }

# row_field ROW NAME: the trimmed value of one column, or empty.
row_field() {
    local row="$1" name="$2" idx v
    local -a fields=()
    idx="${COL[$name]:-}"
    [[ -n "$idx" ]] || return 0
    IFS=',' read -ra fields <<< "$row"
    v="${fields[$idx]:-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

norm_region() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

short_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-10
    else
        printf '%s' "$1" | sha256sum | cut -c1-10
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight: local checks for every row. No Azure change happens until this
# passes.
# -----------------------------------------------------------------------------
PREFLIGHT_ERRORS=()
for row in "${DATA_ROWS[@]}"; do
    sub="$(row_field "$row" subscription_id)"
    vm_rg="$(row_field "$row" vm_resource_group)"
    vm_name="$(row_field "$row" vm_name)"
    if [[ -z "$sub" || -z "$vm_rg" || -z "$vm_name" ]]; then
        PREFLIGHT_ERRORS+=("missing subscription_id, vm_resource_group or vm_name: $row")
        continue
    fi
    validate_azure_subscription_id "$sub" || PREFLIGHT_ERRORS+=("$vm_name: subscription_id is not a GUID")

    rk="$(expand_path "$(row_field "$row" root_key_path)")"
    [[ -n "$rk" ]] || rk="$ROOT_KEY"
    [[ -n "$rk" && -f "$rk" ]] || PREFLIGHT_ERRORS+=("$vm_name: root key file missing (set root_key_path or --root-key)")

    nk="$(expand_path "$(row_field "$row" nonroot_key_path)")"
    [[ -n "$nk" ]] || nk="$NONROOT_KEY"
    [[ -n "$nk" && -f "$nk" ]] || PREFLIGHT_ERRORS+=("$vm_name: non-root key file missing (set nonroot_key_path or --nonroot-key)")
done

if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
    error "Pre-flight failed. Nothing was changed in Azure. Fix these rows and re-run:"
    for e in "${PREFLIGHT_ERRORS[@]}"; do
        error "  $e"
    done
    exit 1
fi
ok "Pre-flight passed for ${#DATA_ROWS[@]} row(s)"

# -----------------------------------------------------------------------------
# Hub VNet and proxy CIDR, resolved once.
# -----------------------------------------------------------------------------
az account set --subscription "$SUBSCRIPTION_ID"

if [[ -n "${EXISTING_ACI_SUBNET:-}" && -n "${EXISTING_VNET_NAME:-}" ]]; then
    HUB_VNET_RG="$EXISTING_VNET_RG"
    HUB_VNET_NAME="$EXISTING_VNET_NAME"
    PROXY_CIDR="$(az network vnet subnet show --resource-group "$EXISTING_VNET_RG" \
        --vnet-name "$EXISTING_VNET_NAME" --name "$EXISTING_ACI_SUBNET" \
        --query addressPrefix -o tsv)"
elif az network vnet show --resource-group "$RG" --name "$VNET" >/dev/null 2>&1; then
    HUB_VNET_RG="$RG"
    HUB_VNET_NAME="$VNET"
    PROXY_CIDR="$ACI_SUBNET_CIDR"
else
    SUBNET_ID="$(az container show --resource-group "$RG" --name "$ACI_VMPROXY" \
        --query "subnetIds[0].id" -o tsv)"
    HUB_VNET_RG="$(echo "$SUBNET_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
    HUB_VNET_NAME="$(echo "$SUBNET_ID" | sed -n 's|.*/virtualNetworks/\([^/]*\)/.*|\1|p')"
    HUB_SUBNET_NAME="${SUBNET_ID##*/}"
    PROXY_CIDR="$(az network vnet subnet show --resource-group "$HUB_VNET_RG" \
        --vnet-name "$HUB_VNET_NAME" --name "$HUB_SUBNET_NAME" --query addressPrefix -o tsv)"
fi
HUB_VNET_ID="$(az network vnet show --resource-group "$HUB_VNET_RG" --name "$HUB_VNET_NAME" --query id -o tsv)"
[[ -n "$PROXY_CIDR" && -n "$HUB_VNET_ID" ]] || {
    error "Could not resolve the hub VNet or proxy CIDR. Finish a hub install first."
    exit 1
}
ok "Hub VNet $HUB_VNET_NAME ($HUB_VNET_RG), proxy CIDR $PROXY_CIDR"

# -----------------------------------------------------------------------------
# peering_name_to SUBSCRIPTION RG VNET REMOTE_ID
#   Prints the name of an existing peering on VNET that points at REMOTE_ID,
#   or nothing. Azure allows one peering per remote VNet, so this is the
#   check that makes a repeat run skip peerings that are already there.
# -----------------------------------------------------------------------------
peering_name_to() {
    local sub="$1" rg="$2" vnet="$3" remote_id="$4" want
    want="$(printf '%s' "$remote_id" | tr '[:upper:]' '[:lower:]')"
    az network vnet peering list --subscription "$sub" --resource-group "$rg" --vnet-name "$vnet" -o json \
        | jq -r --arg id "$want" \
            '[.[] | select(((.remoteVirtualNetwork.id // "") | ascii_downcase) == $id) | .name] | .[0] // ""'
}

# -----------------------------------------------------------------------------
# ensure_peering TARGET_SUB TARGET_VNET_RG TARGET_VNET_NAME
#   Both directions. Skips a side that already exists. Returns non-zero when a
#   side is not Connected (for example the address spaces overlap).
# -----------------------------------------------------------------------------
ensure_peering() {
    local target_sub="$1" target_vnet_rg="$2" target_vnet_name="$3"
    local peer_key target_vnet_id hub_name target_name state

    peer_key="${target_sub}/${target_vnet_rg}/${target_vnet_name}"
    if [[ "$(progress_peering "$peer_key")" == "connected" ]]; then
        ok "Peering already Connected (recorded): $target_vnet_name"
        return 0
    fi

    target_vnet_id="$(az network vnet show --subscription "$target_sub" \
        --resource-group "$target_vnet_rg" --name "$target_vnet_name" --query id -o tsv)"
    [[ -n "$target_vnet_id" ]] || { error "Target VNet not found: $target_vnet_name in $target_vnet_rg"; return 1; }

    # Hub side
    hub_name="$(peering_name_to "$SUBSCRIPTION_ID" "$HUB_VNET_RG" "$HUB_VNET_NAME" "$target_vnet_id")"
    if [[ -n "$hub_name" ]]; then
        ok "Hub peering exists: $hub_name"
    elif [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] would create hub peering to $target_vnet_name"
    else
        hub_name="cdx-${NAME_PREFIX}-$(short_hash "$target_vnet_id")"
        az network vnet peering create --subscription "$SUBSCRIPTION_ID" \
            --resource-group "$HUB_VNET_RG" --vnet-name "$HUB_VNET_NAME" \
            --name "$hub_name" --remote-vnet "$target_vnet_id" \
            --allow-vnet-access true --allow-forwarded-traffic true --only-show-errors >/dev/null || return 1
        ok "Hub peering created: $hub_name"
    fi

    # Target side
    target_name="$(peering_name_to "$target_sub" "$target_vnet_rg" "$target_vnet_name" "$HUB_VNET_ID")"
    if [[ -n "$target_name" ]]; then
        ok "Target peering exists: $target_name"
    elif [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] would create target peering cdx-${NAME_PREFIX}-to-hub on $target_vnet_name"
        return 0
    else
        target_name="cdx-${NAME_PREFIX}-to-hub"
        az network vnet peering create --subscription "$target_sub" \
            --resource-group "$target_vnet_rg" --vnet-name "$target_vnet_name" \
            --name "$target_name" --remote-vnet "$HUB_VNET_ID" \
            --allow-vnet-access true --allow-forwarded-traffic true --only-show-errors >/dev/null || return 1
        ok "Target peering created: $target_name"
    fi

    state="$(az network vnet peering show --subscription "$target_sub" \
        --resource-group "$target_vnet_rg" --vnet-name "$target_vnet_name" \
        --name "$target_name" --query peeringState -o tsv)"
    if [[ "$state" != "Connected" ]]; then
        error "Peering is '$state', not Connected, for $target_vnet_name. Check that the address spaces do not overlap."
        return 1
    fi
    progress_mark_peering "$peer_key" "connected"
    ok "Peering Connected: $target_vnet_name"
}

# -----------------------------------------------------------------------------
# ensure_nsg TARGET_SUB NIC_ID
#   Allows TCP 22 from the proxy CIDR on the NIC's NSG, or on its subnet's NSG.
#   An existing AllowCdxProxySsh rule is updated, not duplicated.
# -----------------------------------------------------------------------------
ensure_nsg() {
    local target_sub="$1" nic_id="$2"
    local nsg_id subnet_id nsg_rg nsg_name nsg_key priority used

    nsg_id="$(az network nic show --subscription "$target_sub" --ids "$nic_id" \
        --query "networkSecurityGroup.id" -o tsv)"
    if [[ -z "$nsg_id" ]]; then
        subnet_id="$(az network nic show --subscription "$target_sub" --ids "$nic_id" \
            --query "ipConfigurations[0].subnet.id" -o tsv)"
        nsg_id="$(az network vnet subnet show --subscription "$target_sub" --ids "$subnet_id" \
            --query "networkSecurityGroup.id" -o tsv)"
    fi
    if [[ -z "$nsg_id" ]]; then
        error "No NSG on the NIC or its subnet. Allow TCP 22 from $PROXY_CIDR yourself."
        return 1
    fi
    nsg_rg="$(echo "$nsg_id" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
    nsg_name="${nsg_id##*/}"
    nsg_key="${target_sub}/${nsg_rg}/${nsg_name}"

    if [[ "$(progress_nsg "$nsg_key")" == "ok" ]]; then
        ok "NSG already allows the proxy (recorded): $nsg_name"
        return 0
    fi

    if az network nsg rule show --subscription "$target_sub" --resource-group "$nsg_rg" \
        --nsg-name "$nsg_name" --name AllowCdxProxySsh >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[dry-run] AllowCdxProxySsh exists on $nsg_name; would check its source"
            return 0
        fi
        az network nsg rule update --subscription "$target_sub" --resource-group "$nsg_rg" \
            --nsg-name "$nsg_name" --name AllowCdxProxySsh \
            --source-address-prefixes "$PROXY_CIDR" --only-show-errors >/dev/null || return 1
    else
        if [[ "$DRY_RUN" == true ]]; then
            info "[dry-run] would add AllowCdxProxySsh on $nsg_name from $PROXY_CIDR"
            return 0
        fi
        priority=1000
        used="$(az network nsg rule list --subscription "$target_sub" --resource-group "$nsg_rg" \
            --nsg-name "$nsg_name" --query "[].priority" -o tsv)"
        while printf '%s\n' "$used" | grep -qx "$priority"; do
            priority=$((priority + 1))
            if (( priority > 4096 )); then
                error "No free priority on NSG $nsg_name"
                return 1
            fi
        done
        az network nsg rule create --subscription "$target_sub" --resource-group "$nsg_rg" \
            --nsg-name "$nsg_name" --name AllowCdxProxySsh --priority "$priority" \
            --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 22 \
            --source-address-prefixes "$PROXY_CIDR" --only-show-errors >/dev/null || return 1
    fi
    progress_mark_nsg "$nsg_key" "ok"
    ok "NSG $nsg_name allows TCP 22 from $PROXY_CIDR"
}

# -----------------------------------------------------------------------------
# store_user_key VM_NAME VM_ID OS_USER KEY_FILE
#   Writes <vmId>-<user> and <vm-name>-<user>. Key Vault overwrites the same
#   name, so a repeat run is safe.
# -----------------------------------------------------------------------------
store_user_key() {
    local vm_name="$1" vm_id="$2" os_user="$3" key_file="$4"
    local name_secret id_secret

    name_secret="$(azure_key_secret_name "$vm_name" "$os_user")"
    id_secret="$(azure_key_secret_name "$vm_id" "$os_user")"

    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] would store secrets $id_secret and $name_secret"
        return 0
    fi
    az account set --subscription "$SUBSCRIPTION_ID"
    set_secret_file "$KV_KEYS" "$id_secret" "$key_file" || return 1
    if [[ "$name_secret" != "$id_secret" ]]; then
        set_secret_file "$KV_KEYS" "$name_secret" "$key_file" || return 1
    fi
}

# -----------------------------------------------------------------------------
# Process rows
# -----------------------------------------------------------------------------
TOTAL=${#DATA_ROWS[@]}
N=0
OK_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
FAILED_ROWS=()

fail_row() {
    local key="$1" msg="$2"
    error "$msg"
    FAILED_ROWS+=("$key: $msg")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ "$DRY_RUN" != true ]]; then
        progress_mark_vm "$key" "failed"
    fi
}

for row in "${DATA_ROWS[@]}"; do
    N=$((N + 1))
    sub="$(row_field "$row" subscription_id)"
    vm_rg="$(row_field "$row" vm_resource_group)"
    vm_name="$(row_field "$row" vm_name)"
    region="$(row_field "$row" region)"
    root_user="$(row_field "$row" root_user)"
    nonroot_user="$(row_field "$row" nonroot_user)"
    vnet_name="$(row_field "$row" vnet_name)"
    vnet_rg="$(row_field "$row" vnet_resource_group)"
    rk="$(expand_path "$(row_field "$row" root_key_path)")"
    nk="$(expand_path "$(row_field "$row" nonroot_key_path)")"
    [[ -n "$root_user" ]] || root_user="$ROOT_USER_DEFAULT"
    [[ -n "$nonroot_user" ]] || nonroot_user="$NONROOT_USER_DEFAULT"
    [[ -n "$rk" ]] || rk="$ROOT_KEY"
    [[ -n "$nk" ]] || nk="$NONROOT_KEY"

    vmkey="${sub}/${vm_rg}/${vm_name}"
    step "[$N/$TOTAL] $vm_name ($vm_rg)"

    if [[ "$(progress_vm_status "$vmkey")" == "complete" ]]; then
        ok "Already complete. Skipping."
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if ! vm_json="$(az vm show --subscription "$sub" --resource-group "$vm_rg" --name "$vm_name" \
        -o json 2>/dev/null)"; then
        fail_row "$vmkey" "VM not found: $vm_name in $vm_rg"
        continue
    fi
    vm_id="$(printf '%s' "$vm_json" | jq -r '.vmId // ""')"
    location="$(printf '%s' "$vm_json" | jq -r '.location // ""')"
    nic_id="$(printf '%s' "$vm_json" | jq -r '.networkProfile.networkInterfaces[0].id // ""')"
    if [[ -z "$vm_id" || -z "$nic_id" ]]; then
        fail_row "$vmkey" "VM has no vmId or NIC: $vm_name"
        continue
    fi
    if [[ -n "$region" && "$(norm_region "$region")" != "$(norm_region "$location")" ]]; then
        fail_row "$vmkey" "Region mismatch for $vm_name: CSV says $region, VM is $location"
        continue
    fi

    if [[ -z "$vnet_name" || -z "$vnet_rg" ]]; then
        subnet_id="$(az network nic show --subscription "$sub" --ids "$nic_id" \
            --query "ipConfigurations[0].subnet.id" -o tsv)"
        vnet_rg="$(echo "$subnet_id" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
        vnet_name="$(echo "$subnet_id" | sed -n 's|.*/virtualNetworks/\([^/]*\)/.*|\1|p')"
    fi

    if ! ensure_peering "$sub" "$vnet_rg" "$vnet_name"; then
        fail_row "$vmkey" "Peering failed for $vm_name ($vnet_name)"
        continue
    fi
    if ! ensure_nsg "$sub" "$nic_id"; then
        fail_row "$vmkey" "NSG step failed for $vm_name"
        continue
    fi
    if ! store_user_key "$vm_name" "$vm_id" "$root_user" "$rk"; then
        fail_row "$vmkey" "Root key store failed for $vm_name"
        continue
    fi
    if ! store_user_key "$vm_name" "$vm_id" "$nonroot_user" "$nk"; then
        fail_row "$vmkey" "Non-root key store failed for $vm_name"
        continue
    fi

    if [[ "$DRY_RUN" != true ]]; then
        progress_mark_vm "$vmkey" "complete" "$vm_id" "$root_user" "$nonroot_user"
    fi
    OK_COUNT=$((OK_COUNT + 1))
    if [[ "$DRY_RUN" == true ]]; then
        ok "Would onboard $vm_name ($root_user + $nonroot_user)"
    else
        ok "Onboarded $vm_name ($root_user + $nonroot_user)"
    fi
done

echo ""
ok "Bulk onboard finished. rows=$TOTAL ok=$OK_COUNT skipped=$SKIP_COUNT failed=$FAIL_COUNT"
if [[ "$DRY_RUN" == true ]]; then
    warn "Dry run. Nothing was changed."
fi
if (( FAIL_COUNT > 0 )); then
    warn "Failed rows:"
    for r in "${FAILED_ROWS[@]}"; do
        warn "  $r"
    done
    warn "Fix the cause and re-run the same command. Completed VMs are skipped."
    exit 1
fi
