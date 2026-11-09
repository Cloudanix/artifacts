#!/usr/bin/env bash
# =============================================================================
# Azure JIT VM — Master Orchestrator
# =============================================================================
# Usage:
#   ./setup.sh              — Run the setup wizard (resumes from .state.json).
#                             A finished hub offers bulk onboard instead of resume.
#   ./setup.sh --share      — Print the hub details Cloudanix needs (no secrets)
#   ./setup.sh --cleanup    — Remove the hub resource group and peerings this setup created
#   ./refresh-forwarders.sh — Re-point jump-VM forwarders after an ACI replacement
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Source shared library
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    echo "[ERROR] Shared library not found: $LIB_DIR/common.sh" >&2
    echo "        Expected at: $LIB_DIR/common.sh" >&2
    exit 1
fi
source "$LIB_DIR/common.sh"

# Source configuration schema
source "$SCRIPT_DIR/config.sh"

# State file location
STATE_FILE="$SCRIPT_DIR/.state.json"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

MODE_ARG=""
for _arg in "$@"; do
    case "$_arg" in
        --share|--cleanup) MODE_ARG="$_arg" ;;
        *)
            error "Unknown argument: $_arg"
            echo "Usage: ./setup.sh [--share|--cleanup]" >&2
            exit 1
            ;;
    esac
done

if [[ "$MODE_ARG" == "--share" ]]; then
    check_prerequisites "${PREREQUISITES[@]}" || exit 1
    cdx_share_summary "$STATE_FILE" "$SETUP_TYPE"
    exit $?
fi

# =============================================================================
# CLEANUP MODE
# =============================================================================

if [[ "$MODE_ARG" == "--cleanup" ]]; then
    check_prerequisites "${PREREQUISITES[@]}" || exit 1
    echo ""
    echo -e "${_CLR_BOLD}=== Cleanup: $SETUP_DISPLAY_NAME ===${_CLR_RESET}"
    echo ""
    if [[ -f "$STATE_FILE" ]] && load_state "$STATE_FILE" >/dev/null 2>&1; then
        info "Found setup state: $STATE_FILE"
    else
        info "No (valid) state file. The cleanup script will ask for the name prefix."
    fi
    echo ""
    warn "This removes the hub resource group and the peerings this setup created."
    if ! prompt_yes_no "Proceed with cleanup?" "n"; then
        info "Cleanup cancelled."
        exit 0
    fi
    source "$SCRIPT_DIR/cleanup/cleanup.sh"
    exit 0
fi

# =============================================================================
# FINISHED HUB MENU
# =============================================================================

# hub_setup_complete SCOPE
#   True when a hub install (new-vnet or existing-vnet) has every step done.
#   06-jump-forwarders exists only in the hub scopes, so an onboard-only state
#   file falls through to the normal resume prompt.
hub_setup_complete() {
    local scope="$1" step_id
    is_step_complete "$STATE_FILE" "06-jump-forwarders" || return 1
    for step_id in ${STEPS_FOR_MODE[$scope]:-}; do
        is_step_complete "$STATE_FILE" "$step_id" || return 1
    done
}

# run_bulk_onboard
#   Asks for a CSV, runs bulk-onboard.sh as a dry run first, and only does the
#   real run if the user confirms. Never writes .state.json.
run_bulk_onboard() {
    local csv_path
    csv_path="$(prompt_with_default "Path to the CSV of VMs to onboard" "./vms.csv")"
    csv_path="${csv_path/#\~/$HOME}"
    [[ -f "$csv_path" ]] || { error "CSV not found: $csv_path"; return 1; }

    if prompt_yes_no "Dry run first? It checks every row and changes nothing" "y"; then
        bash "$SCRIPT_DIR/bulk-onboard.sh" --csv "$csv_path" --dry-run || return 1
        echo ""
        if ! prompt_yes_no "Run for real now?" "n"; then
            info "Stopped. Nothing was changed in Azure."
            return 0
        fi
    fi
    bash "$SCRIPT_DIR/bulk-onboard.sh" --csv "$csv_path"
}

# finished_hub_menu
#   Shown when the saved hub setup is complete, so there is nothing to resume.
#   Bulk onboard keeps the hub. Start over deletes the state after a confirm.
finished_hub_menu() {
    prompt_selection "The hub setup is complete. What do you want to do?" \
        "$BULK_ONBOARD_LABEL" \
        "Start over (deletes the saved hub state)" \
        "Exit" || exit 1
    case "$CDX_SELECTED" in
        "$BULK_ONBOARD_LABEL")
            run_bulk_onboard || exit 1
            exit 0
            ;;
        Start*)
            if prompt_yes_no "This deletes the saved hub state. Start over?" "n"; then
                rm -f "$STATE_FILE"
                info "Previous state cleared."
            else
                info "Nothing changed."
                exit 0
            fi
            ;;
        *)
            exit 0
            ;;
    esac
}

# =============================================================================
# MAIN SETUP FLOW
# =============================================================================

echo ""
echo -e "${_CLR_BOLD}╔══════════════════════════════════════════════════════════════════╗${_CLR_RESET}"
echo -e "${_CLR_BOLD}  $SETUP_DISPLAY_NAME Setup${_CLR_RESET}"
echo -e "${_CLR_BOLD}╚══════════════════════════════════════════════════════════════════╝${_CLR_RESET}"
echo ""

# Check prerequisites
check_prerequisites "${PREREQUISITES[@]}" || exit 1
ok "All prerequisites available: ${PREREQUISITES[*]}"

# =============================================================================
# STATE: RESUME OR FRESH
# =============================================================================

RESUME_MODE=false
SELECTED_SCOPE_MODE=""

if [[ -f "$STATE_FILE" ]]; then
    local_state=$(load_state "$STATE_FILE")
    if [[ $? -eq 0 ]]; then
        existing_scope=$(echo "$local_state" | jq -r '.scope_mode')
        existing_label=""
        for i in "${!SCOPE_MODES[@]}"; do
            if [[ "${SCOPE_MODES[$i]}" == "$existing_scope" ]]; then
                existing_label="${SCOPE_MODE_LABELS[$i]}"
                break
            fi
        done

        echo ""
        info "Found existing setup state (scope: $existing_label)"
        echo ""

        if hub_setup_complete "$existing_scope"; then
            finished_hub_menu
        elif prompt_yes_no "Resume from where you left off?" "y"; then
            RESUME_MODE=true
            SELECTED_SCOPE_MODE="$existing_scope"
        else
            if prompt_yes_no "Start fresh? (This will delete the existing state)" "n"; then
                rm -f "$STATE_FILE"
                info "Previous state cleared."
            else
                info "Exiting. State file preserved."
                exit 0
            fi
        fi
    else
        warn "State file exists but is corrupted."
        if prompt_yes_no "Start fresh? (This will delete the corrupted state)" "n"; then
            rm -f "$STATE_FILE"
        else
            error "Cannot proceed with corrupted state file. Exiting."
            exit 1
        fi
    fi
fi

# =============================================================================
# SCOPE MODE SELECTION
# =============================================================================

if [[ -z "$SELECTED_SCOPE_MODE" ]]; then
    # prompt_selection prints the menu and returns its choice in CDX_SELECTED,
    # so it must not run inside $(...).
    prompt_selection "Select deployment scope:" "${SCOPE_MODE_LABELS[@]}" || {
        error "Failed to select scope mode."
        exit 1
    }
    SELECTED_LABEL="$CDX_SELECTED"

    # Map label back to mode identifier
    for i in "${!SCOPE_MODE_LABELS[@]}"; do
        if [[ "${SCOPE_MODE_LABELS[$i]}" == "$SELECTED_LABEL" ]]; then
            SELECTED_SCOPE_MODE="${SCOPE_MODES[$i]}"
            break
        fi
    done
fi

info "Scope mode: $SELECTED_SCOPE_MODE"

# =============================================================================
# DETERMINE STEPS FOR SELECTED MODE
# =============================================================================

STEPS_STR="${STEPS_FOR_MODE[$SELECTED_SCOPE_MODE]}"
ALL_STEPS=($STEPS_STR)
TOTAL_STEPS=${#ALL_STEPS[@]}

# =============================================================================
# CONFIGURATION COLLECTION
# =============================================================================

if [[ "$RESUME_MODE" == false ]]; then
    # Initialize state file
    init_state "$STATE_FILE" "$SETUP_TYPE" "$SELECTED_SCOPE_MODE"

    step "Configuration"
    echo ""
    info "Please provide the following values. Press Enter to accept defaults."
    echo ""

    CURRENT_SUB="$(az account show --query id -o tsv 2>/dev/null || true)"
    CURRENT_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"

    for field_def in "${CONFIG_FIELDS[@]}"; do
        IFS='|' read -r field_name field_rule field_default field_prompt field_scopes field_sensitive <<< "$field_def"

        # Check if this field applies to the selected scope mode
        if [[ "$field_scopes" != "*" ]]; then
            IFS=',' read -ra applicable_modes <<< "$field_scopes"
            applies=false
            for mode in "${applicable_modes[@]}"; do
                if [[ "$mode" == "$SELECTED_SCOPE_MODE" ]]; then
                    applies=true
                    break
                fi
            done
            if [[ "$applies" == false ]]; then
                continue
            fi
        fi

        case "$field_name" in
            SUBSCRIPTION_ID|TARGET_SUBSCRIPTION_ID)
                [[ -z "$field_default" && -n "$CURRENT_SUB" ]] && field_default="$CURRENT_SUB"
                ;;
            OPERATOR_OBJECT_ID)
                [[ -z "$field_default" && -n "$CURRENT_OID" ]] && field_default="$CURRENT_OID"
                ;;
            SSH_ALLOWED_CIDRS)
                if prompt_yes_no "Do you have a VPN CIDR to allow for SSH to the jump VM?" "n"; then
                    while true; do
                        value=$(prompt_with_default "VPN CIDR or CIDRs, comma-separated" "")
                        ok_cidrs=true
                        while IFS= read -r cidr; do
                            [[ -z "$cidr" ]] && continue
                            if ! validate_cidr "$cidr"; then
                                warn "Invalid CIDR: $cidr"
                                ok_cidrs=false
                            fi
                        done < <(printf '%s\n' "$value" | tr ',' '\n' | tr -d ' \t')
                        [[ "$ok_cidrs" == true && -n "$value" ]] && break
                    done
                else
                    value="0.0.0.0/0"
                    info "No VPN CIDR. SSH to the jump VM will allow 0.0.0.0/0."
                fi
                set_config_value "$STATE_FILE" "$field_name" "$value"
                continue
                ;;
            JUMP_VM_SSH_PUBLIC_KEY_FILE)
                jump_key="${HOME}/.ssh/cdx-azure-jit-jump"
                mkdir -p "${HOME}/.ssh"
                chmod 700 "${HOME}/.ssh"
                if [[ ! -f "${jump_key}.pub" ]]; then
                    ssh-keygen -q -t ed25519 -f "$jump_key" -N "" -C "cdx-azure-jit-jump"
                    chmod 600 "$jump_key"
                    info "Created jump VM SSH key: ${jump_key}.pub"
                else
                    info "Using existing jump VM SSH key: ${jump_key}.pub"
                fi
                set_config_value "$STATE_FILE" "$field_name" "${jump_key}.pub"
                continue
                ;;
            ACR_RESOURCE_ID)
                registry="$(get_config_value "$STATE_FILE" "IMAGE_REGISTRY")"
                hub_sub="$(get_config_value "$STATE_FILE" "SUBSCRIPTION_ID")"
                [[ -n "$hub_sub" ]] && az account set --subscription "$hub_sub" >/dev/null
                acr_id="$(az acr show --name "${registry%%.*}" --query id -o tsv 2>/dev/null || true)"
                if [[ -n "$acr_id" ]]; then
                    info "Registry resource ID: $acr_id"
                    set_config_value "$STATE_FILE" "$field_name" "$acr_id"
                    continue
                fi
                field_prompt="Full resource ID of ${registry} (for example /subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.ContainerRegistry/registries/${registry%%.*})"
                ;;
        esac

        # Prompt for value with validation
        while true; do
            value=$(prompt_with_default "$field_prompt" "$field_default")

            if validate "$value" "$field_rule"; then
                set_config_value "$STATE_FILE" "$field_name" "$value"
                break
            else
                warn "Invalid format. Expected: $field_rule"
            fi
        done
    done

    # Display configuration summary
    echo ""
    step "Configuration Summary"
    echo ""

    for field_def in "${CONFIG_FIELDS[@]}"; do
        IFS='|' read -r field_name field_rule field_default field_prompt field_scopes field_sensitive <<< "$field_def"

        if [[ "$field_scopes" != "*" ]]; then
            IFS=',' read -ra applicable_modes <<< "$field_scopes"
            applies=false
            for mode in "${applicable_modes[@]}"; do
                if [[ "$mode" == "$SELECTED_SCOPE_MODE" ]]; then
                    applies=true
                    break
                fi
            done
            if [[ "$applies" == false ]]; then
                continue
            fi
        fi

        stored_value=$(get_config_value "$STATE_FILE" "$field_name")
        case "$field_name" in
            SUBSCRIPTION_ID) summary_label="Hub subscription" ;;
            TARGET_SUBSCRIPTION_ID) summary_label="Target subscription" ;;
            LOCATION) summary_label="Region" ;;
            HUB_VNET_CIDR) summary_label="Hub VNet CIDR" ;;
            NAME_PREFIX) summary_label="Name prefix" ;;
            SSH_ALLOWED_CIDRS) summary_label="Jump SSH CIDRs" ;;
            OPERATOR_OBJECT_ID) summary_label="Operator object ID" ;;
            JUMP_VM_ADMIN_USERNAME) summary_label="Jump admin user" ;;
            JUMP_VM_SSH_PUBLIC_KEY_FILE) summary_label="Jump SSH public key" ;;
            IMAGE_REGISTRY) summary_label="Registry" ;;
            ACR_RESOURCE_ID) summary_label="Registry resource ID" ;;
            IMAGE_TAG) summary_label="Image tag" ;;
            SSHPIPER_IMAGE) summary_label="sshpiper image" ;;
            VMPROXY_IMAGE) summary_label="VM proxy image" ;;
            LOGGING_IMAGE) summary_label="Logging image" ;;
            CDX_API_BASE) summary_label="API base URL" ;;
            CDX_DC) summary_label="Data center" ;;
            LOG_CONTAINER) summary_label="Log container" ;;
            TARGET_VNET_NAME) summary_label="Target VNet" ;;
            TARGET_VNET_RG) summary_label="Target VNet resource group" ;;
            TARGET_VM_NAME) summary_label="Target VM" ;;
            TARGET_VM_RG) summary_label="Target VM resource group" ;;
            TARGET_VM_OS_USER) summary_label="Target OS user" ;;
            TARGET_SSH_PRIVATE_KEY_FILE) summary_label="Target SSH private key" ;;
            *) summary_label="$field_name" ;;
        esac

        if [[ "$field_sensitive" == "true" ]]; then
            masked=$(mask_sensitive "$stored_value")
            echo "  $summary_label: $masked"
        else
            echo "  $summary_label: $stored_value"
        fi
    done

    echo ""
    if ! prompt_yes_no "Proceed with these values?" "y"; then
        # Allow re-editing specific values
        info "You can re-run the script to change values. State has been saved."
        exit 0
    fi
fi

# =============================================================================
# STEP EXECUTION LOOP
# =============================================================================

step "Executing Setup Steps"
echo ""
info "Total steps: $TOTAL_STEPS"

CURRENT_ACCOUNT=""
STEP_NUM=0

for step_id in "${ALL_STEPS[@]}"; do
    STEP_NUM=$((STEP_NUM + 1))

    # Skip completed steps in resume mode
    if is_step_complete "$STATE_FILE" "$step_id"; then
        info "[Step ${STEP_NUM}/${TOTAL_STEPS}] ${STEP_LABELS[$step_id]:-$step_id} — already complete, skipping"
        continue
    fi

    step_label="${STEP_LABELS[$step_id]:-$step_id}"
    step_account="${STEP_ACCOUNT[$step_id]:-unknown}"

    # Account context switch check
    if [[ "$step_account" != "$CURRENT_ACCOUNT" ]]; then
        account_label="${ACCOUNT_LABELS[$step_account]:-$step_account}"
        account_id_field="${ACCOUNT_ID_FIELD[$step_account]:-}"
        expected_account_id=""

        if [[ -n "$account_id_field" ]]; then
            expected_account_id=$(get_config_value "$STATE_FILE" "$account_id_field")
        fi

        if [[ -n "$expected_account_id" ]] && [[ "$step_account" == *"subscription"* ]]; then
            current_sub="$(az account show --query id -o tsv 2>/dev/null || true)"
        else
            current_sub=""
        fi
        if [[ -n "$current_sub" && "$current_sub" == "$expected_account_id" ]]; then
            ok "Already using subscription $expected_account_id"
        else
            show_account_switch_banner "$account_label" "$expected_account_id" "$step_label"

            # Prompt for confirmation and verify credentials
            if ! prompt_yes_no "Have you switched to the correct account?" "y"; then
                warn "Please switch accounts and re-run the script. Progress has been saved."
                exit 0
            fi

            # Verify account credentials if AWS
            if [[ -n "$expected_account_id" ]] && [[ "$expected_account_id" != "" ]]; then
                if [[ "$step_account" == *"subscription"* ]]; then
                    actual_id=$(verify_azure_subscription "$expected_account_id") && true
                    if [[ $? -ne 0 ]] && [[ -n "$actual_id" ]]; then
                        error "Account mismatch!"
                        error "  Expected: $expected_account_id"
                        error "  Actual:   $actual_id"
                        warn "Please switch to the correct account and re-run."
                        exit 1
                    fi
                else
                    actual_id=$(verify_aws_account "$expected_account_id") && true
                    if [[ $? -ne 0 ]] && [[ -n "$actual_id" ]]; then
                        error "Account mismatch!"
                        error "  Expected: $expected_account_id"
                        error "  Actual:   $actual_id"
                        warn "Please switch to the correct account and re-run."
                        exit 1
                    fi
                fi
                ok "Account verified: $expected_account_id"
            fi
        fi

        CURRENT_ACCOUNT="$step_account"
    fi

    # Display progress
    show_progress "$STEP_NUM" "$TOTAL_STEPS" "$step_label"

    # Build environment for step script
    step_script="$SCRIPT_DIR/steps/${step_id}.sh"
    if [[ ! -f "$step_script" ]]; then
        error "Step script not found: $step_script"
        exit 1
    fi

    # Export all config values as environment variables
    config_json=$(jq -r '.config' "$STATE_FILE")
    while IFS='=' read -r key value; do
        export "$key=$value"
    done < <(echo "$config_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

    # Export outputs from all previous completed steps
    steps_json=$(jq -r '.steps' "$STATE_FILE")
    while IFS='=' read -r key value; do
        if [[ -n "$key" ]] && [[ "$key" != "null" ]]; then
            export "$key=$value"
        fi
    done < <(echo "$steps_json" | jq -r '[.[] | select(.status == "complete") | .outputs // {} | to_entries[]] | .[] | "\(.key)=\(.value)"')

    # Run the step in the foreground so long Azure calls show progress.
    # OUTPUT: lines stay in the log file and are not printed.
    step_log="$(mktemp)"
    set +e
    set +o pipefail
    bash "$step_script" 2>&1 | tee "$step_log" | grep -v --line-buffered '^OUTPUT:'
    step_exit_code=${PIPESTATUS[0]}
    set -o pipefail
    set -e
    step_output="$(cat "$step_log")"
    rm -f "$step_log"

    if [[ $step_exit_code -ne 0 ]]; then
        error "Step '$step_label' failed with exit code $step_exit_code"
        error "Progress has been saved. Re-run to resume from this step."
        exit $step_exit_code
    fi

    # Parse OUTPUT lines and save to state
    outputs_json=$(parse_step_output "$step_output")

    mark_step_complete "$STATE_FILE" "$step_id" "$outputs_json"
    ok "$step_label — complete"
done

# =============================================================================
# COMPLETION SUMMARY
# =============================================================================

echo ""
echo -e "${_CLR_BOLD}╔══════════════════════════════════════════════════════════════════╗${_CLR_RESET}"
echo -e "${_CLR_BOLD}║  ✅  Setup Complete!                                             ║${_CLR_RESET}"
echo -e "${_CLR_BOLD}╚══════════════════════════════════════════════════════════════════╝${_CLR_RESET}"
echo ""
echo "  Setup Type: $SETUP_DISPLAY_NAME"
echo "  Scope Mode: $SELECTED_SCOPE_MODE"
echo ""
echo "  Steps completed:"
for step_id in "${ALL_STEPS[@]}"; do
    echo "    ✓ ${STEP_LABELS[$step_id]:-$step_id}"
done
echo ""
echo ""
