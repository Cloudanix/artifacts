#!/usr/bin/env bash
# =============================================================================
# AWS JIT Database — Master Orchestrator
# =============================================================================
# Usage:
#   ./setup.sh            — Run the setup wizard
#   ./setup.sh --cleanup  — Tear down resources created by a previous setup
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
# CLEANUP MODE
# =============================================================================

if [[ "${1:-}" == "--cleanup" ]]; then
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No state file found. Nothing to clean up."
        exit 1
    fi

    local_state=$(load_state "$STATE_FILE") || {
        error "State file is corrupted. Cannot determine what to clean up."
        exit 1
    }

    echo ""
    echo -e "${_CLR_BOLD}=== Cleanup: $SETUP_DISPLAY_NAME ===${_CLR_RESET}"
    echo ""
    echo "The following steps were completed:"
    echo ""

    local scope_mode
    scope_mode=$(echo "$local_state" | jq -r '.scope_mode')
    local steps_str="${STEPS_FOR_MODE[$scope_mode]}"
    local all_steps=($steps_str)

    local completed_steps=()
    for s in "${all_steps[@]}"; do
        if is_step_complete "$STATE_FILE" "$s"; then
            local label="${STEP_LABELS[$s]:-$s}"
            local account="${STEP_ACCOUNT[$s]:-unknown}"
            echo "  ✓ $label (${ACCOUNT_LABELS[$account]:-$account})"
            completed_steps+=("$s")
        fi
    done

    echo ""
    if [[ ${#completed_steps[@]} -eq 0 ]]; then
        info "No steps completed. Nothing to clean up."
        exit 0
    fi

    if ! prompt_yes_no "Proceed with cleanup? This will remove all created resources" "n"; then
        info "Cleanup cancelled."
        exit 0
    fi

    # Execute cleanup script if it exists
    if [[ -f "$SCRIPT_DIR/cleanup/cleanup.sh" ]]; then
        source "$SCRIPT_DIR/cleanup/cleanup.sh"
    else
        warn "No cleanup script found at $SCRIPT_DIR/cleanup/cleanup.sh"
    fi

    exit 0
fi

# =============================================================================
# MAIN SETUP FLOW
# =============================================================================

echo ""
echo -e "${_CLR_BOLD}╔══════════════════════════════════════════════════════════════════╗${_CLR_RESET}"
echo -e "${_CLR_BOLD}║            $SETUP_DISPLAY_NAME Setup                            ║${_CLR_RESET}"
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
        local existing_scope
        existing_scope=$(echo "$local_state" | jq -r '.scope_mode')
        local existing_label=""
        for i in "${!SCOPE_MODES[@]}"; do
            if [[ "${SCOPE_MODES[$i]}" == "$existing_scope" ]]; then
                existing_label="${SCOPE_MODE_LABELS[$i]}"
                break
            fi
        done

        echo ""
        info "Found existing setup state (scope: $existing_label)"
        echo ""

        if prompt_yes_no "Resume from where you left off?" "y"; then
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
    SELECTED_SCOPE_MODE=$(prompt_selection "Select deployment scope:" "${SCOPE_MODE_LABELS[@]}") || {
        error "Failed to select scope mode."
        exit 1
    }

    # Map label back to mode identifier
    for i in "${!SCOPE_MODE_LABELS[@]}"; do
        if [[ "${SCOPE_MODE_LABELS[$i]}" == "$SELECTED_SCOPE_MODE" ]]; then
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

    for field_def in "${CONFIG_FIELDS[@]}"; do
        IFS='|' read -r field_name field_rule field_default field_prompt field_scopes field_sensitive <<< "$field_def"

        # Check if this field applies to the selected scope mode
        if [[ "$field_scopes" != "*" ]]; then
            IFS=',' read -ra applicable_modes <<< "$field_scopes"
            local applies=false
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

        # Prompt for value with validation
        while true; do
            local value
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
            local applies=false
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

        local stored_value
        stored_value=$(get_config_value "$STATE_FILE" "$field_name")

        if [[ "$field_sensitive" == "true" ]]; then
            local masked
            masked=$(mask_sensitive "$stored_value")
            echo "  $field_prompt: $masked"
        else
            echo "  $field_prompt: $stored_value"
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

    local step_label="${STEP_LABELS[$step_id]:-$step_id}"
    local step_account="${STEP_ACCOUNT[$step_id]:-unknown}"

    # Account context switch check
    if [[ "$step_account" != "$CURRENT_ACCOUNT" ]]; then
        local account_label="${ACCOUNT_LABELS[$step_account]:-$step_account}"
        local account_id_field="${ACCOUNT_ID_FIELD[$step_account]:-}"
        local expected_account_id=""

        if [[ -n "$account_id_field" ]]; then
            expected_account_id=$(get_config_value "$STATE_FILE" "$account_id_field")
        fi

        show_account_switch_banner "$account_label" "$expected_account_id" "$step_label"

        # Prompt for confirmation and verify credentials
        if ! prompt_yes_no "Have you switched to the correct account?" "y"; then
            warn "Please switch accounts and re-run the script. Progress has been saved."
            exit 0
        fi

        # Verify account credentials if AWS
        if [[ -n "$expected_account_id" ]] && [[ "$expected_account_id" != "" ]]; then
            if [[ "$step_account" == *"subscription"* ]]; then
                # Azure verification
                local actual_id
                actual_id=$(verify_azure_subscription "$expected_account_id") && true
                if [[ $? -ne 0 ]] && [[ -n "$actual_id" ]]; then
                    error "Account mismatch!"
                    error "  Expected: $expected_account_id"
                    error "  Actual:   $actual_id"
                    warn "Please switch to the correct account and re-run."
                    exit 1
                fi
            else
                # AWS verification
                local actual_id
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

        CURRENT_ACCOUNT="$step_account"
    fi

    # Display progress
    show_progress "$STEP_NUM" "$TOTAL_STEPS" "$step_label"

    # Build environment for step script
    local step_script="$SCRIPT_DIR/steps/${step_id}.sh"
    if [[ ! -f "$step_script" ]]; then
        error "Step script not found: $step_script"
        exit 1
    fi

    # Export all config values as environment variables
    local config_json
    config_json=$(jq -r '.config' "$STATE_FILE")
    while IFS='=' read -r key value; do
        export "$key=$value"
    done < <(echo "$config_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

    # Export outputs from all previous completed steps
    local steps_json
    steps_json=$(jq -r '.steps' "$STATE_FILE")
    while IFS='=' read -r key value; do
        if [[ -n "$key" ]] && [[ "$key" != "null" ]]; then
            export "$key=$value"
        fi
    done < <(echo "$steps_json" | jq -r '[.[] | select(.status == "complete") | .outputs // {} | to_entries[]] | .[] | "\(.key)=\(.value)"')

    # Execute step script and capture output
    local step_output
    local step_exit_code=0
    step_output=$(bash "$step_script" 2>&1) || step_exit_code=$?

    # Display step output (non-OUTPUT lines)
    echo "$step_output" | grep -v "^OUTPUT:" || true

    if [[ $step_exit_code -ne 0 ]]; then
        error "Step '$step_label' failed with exit code $step_exit_code"
        error "Progress has been saved. Re-run to resume from this step."
        exit $step_exit_code
    fi

    # Parse OUTPUT lines and save to state
    local outputs_json
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
echo "  To tear down: ./setup.sh --cleanup"
echo ""
