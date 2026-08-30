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
    echo ""
    echo -e "${_CLR_BOLD}=== Cleanup: $SETUP_DISPLAY_NAME ===${_CLR_RESET}"
    echo ""

    if [[ -f "$STATE_FILE" ]]; then
        info "State file found — will use it for resource hints."
        if load_state "$STATE_FILE" > /dev/null 2>&1; then
            scope_mode=$(jq -r '.scope_mode // "unknown"' "$STATE_FILE" 2>/dev/null)
            info "Recorded scope: $scope_mode"
        fi
    else
        warn "No state file found — cleanup will DISCOVER resources by name/tag."
        info "This finds JIT DB resources (cluster, services, EFS, VPC, roles) automatically."
    fi

    echo ""
    if ! prompt_yes_no "Proceed with cleanup? This will remove JIT DB resources it finds" "n"; then
        info "Cleanup cancelled."
        exit 0
    fi

    if [[ -f "$SCRIPT_DIR/cleanup/cleanup.sh" ]]; then
        source "$SCRIPT_DIR/cleanup/cleanup.sh"
    else
        error "No cleanup script found at $SCRIPT_DIR/cleanup/cleanup.sh"
        error "Re-install to fetch it: curl ... | bash -s -- $SETUP_TYPE"
        exit 1
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
    prompt_selection "Select deployment scope:" "${SCOPE_MODE_LABELS[@]}" || {
        error "Failed to select scope mode."
        exit 1
    }

    # Map label back to mode identifier
    for i in "${!SCOPE_MODE_LABELS[@]}"; do
        if [[ "${SCOPE_MODE_LABELS[$i]}" == "$CDX_SELECTED" ]]; then
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
    init_state "$STATE_FILE" "$SETUP_TYPE" "$SELECTED_SCOPE_MODE"

    # Auto-detect values for smart defaults
    _CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "")
    _SSO_INSTANCE_ARN=$(aws sso-admin list-instances --query "Instances[0].InstanceArn" --output text 2>/dev/null || echo "")

    step "Configuration"
    echo ""
    info "Please provide the following values. Press Enter to accept defaults."
    echo ""

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

        # Resolve auto-defaults
        if [[ "$field_default" == "__AUTO_SSO__" ]]; then
            field_default="${_SSO_INSTANCE_ARN:-}"
        elif [[ "$field_default" == "__AUTO_BUCKET__" ]]; then
            # Use JIT account ID if already collected, otherwise current account
            _jit_id=$(get_config_value "$STATE_FILE" "JIT_ACCOUNT_ID" 2>/dev/null || echo "")
            field_default="cdx-jit-db-logs-${_jit_id:-${_CURRENT_ACCOUNT_ID:-unknown}}"
        fi

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
        if [[ "$field_sensitive" == "true" ]]; then
            masked=$(mask_sensitive "$stored_value")
            echo "  $field_prompt: $masked"
        else
            echo "  $field_prompt: $stored_value"
        fi
    done

    echo ""
    if ! prompt_yes_no "Proceed with these values?" "y"; then
        info "You can re-run the script to change values. State has been saved."
        exit 0
    fi
fi

# =============================================================================
# RE-PROMPT MISSING CONFIG ON RESUME
# =============================================================================

if [[ "$RESUME_MODE" == true ]]; then
    _CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "")
    _SSO_INSTANCE_ARN=$(aws sso-admin list-instances --query "Instances[0].InstanceArn" --output text 2>/dev/null || echo "")

    MISSING_CONFIG=false
    for field_def in "${CONFIG_FIELDS[@]}"; do
        IFS='|' read -r field_name field_rule field_default field_prompt field_scopes field_sensitive <<< "$field_def"

        if [[ "$field_scopes" != "*" ]]; then
            IFS=',' read -ra applicable_modes <<< "$field_scopes"
            applies=false
            for mode in "${applicable_modes[@]}"; do
                if [[ "$mode" == "$SELECTED_SCOPE_MODE" ]]; then applies=true; break; fi
            done
            [[ "$applies" == false ]] && continue
        fi

        stored=$(get_config_value "$STATE_FILE" "$field_name")
        if [[ -z "$stored" ]]; then
            if [[ "$MISSING_CONFIG" == false ]]; then
                echo ""
                info "Some configuration values are missing. Please provide them:"
                echo ""
                MISSING_CONFIG=true
            fi

            if [[ "$field_default" == "__AUTO_SSO__" ]]; then
                field_default="${_SSO_INSTANCE_ARN:-}"
            elif [[ "$field_default" == "__AUTO_BUCKET__" ]]; then
                _jit_id=$(get_config_value "$STATE_FILE" "JIT_ACCOUNT_ID" 2>/dev/null || echo "")
                field_default="cdx-jit-db-logs-${_jit_id:-${_CURRENT_ACCOUNT_ID:-unknown}}"
            fi

            while true; do
                value=$(prompt_with_default "$field_prompt" "$field_default")
                if validate "$value" "$field_rule"; then
                    set_config_value "$STATE_FILE" "$field_name" "$value"
                    break
                else
                    warn "Invalid format. Expected: $field_rule"
                fi
            done
        fi
    done
fi

# =============================================================================
# COLLECT CREDENTIALS FOR ALL ACCOUNTS UP FRONT
# =============================================================================
# We determine which unique accounts are needed for the remaining steps,
# then ask for credentials for each one before any infrastructure work starts.
# This way the user does all the access-portal work at the beginning.
# =============================================================================

step "Account Credentials"
echo ""
info "We need credentials for each AWS account involved in this setup."
info "For each account, paste the temporary credentials from your AWS Access Portal."
echo ""

# Determine unique accounts needed for remaining (incomplete) steps
declare -A ACCOUNT_CREDS_COLLECTED
ACCOUNTS_NEEDED=()

for step_id in "${ALL_STEPS[@]}"; do
    # Skip already completed steps
    if is_step_complete "$STATE_FILE" "$step_id"; then
        continue
    fi

    step_account="${STEP_ACCOUNT[$step_id]:-unknown}"
    if [[ -z "${ACCOUNT_CREDS_COLLECTED[$step_account]:-}" ]]; then
        ACCOUNTS_NEEDED+=("$step_account")
        ACCOUNT_CREDS_COLLECTED["$step_account"]="pending"
    fi
done

if [[ ${#ACCOUNTS_NEEDED[@]} -eq 0 ]]; then
    info "All steps already complete!"
else
    # Store credentials in associative arrays keyed by account context
    declare -A CREDS_ACCESS_KEY
    declare -A CREDS_SECRET_KEY
    declare -A CREDS_SESSION_TOKEN

    for acct_context in "${ACCOUNTS_NEEDED[@]}"; do
        account_label="${ACCOUNT_LABELS[$acct_context]:-$acct_context}"
        account_id_field="${ACCOUNT_ID_FIELD[$acct_context]:-}"
        expected_id=""
        if [[ -n "$account_id_field" ]]; then
            expected_id=$(get_config_value "$STATE_FILE" "$account_id_field")
        fi

        # Check if current creds already match this account
        current_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null) || current_id=""
        if [[ "$current_id" == "$expected_id" && -n "$expected_id" ]]; then
            ok "$account_label ($expected_id) — using current credentials"
            CREDS_ACCESS_KEY["$acct_context"]="${AWS_ACCESS_KEY_ID:-__current__}"
            CREDS_SECRET_KEY["$acct_context"]="${AWS_SECRET_ACCESS_KEY:-__current__}"
            CREDS_SESSION_TOKEN["$acct_context"]="${AWS_SESSION_TOKEN:-}"
            continue
        fi

        # Prompt for credentials
        while true; do
            echo ""
            echo -e "${_CLR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_RESET}"
            echo -e "${_CLR_BOLD}  ${account_label}${_CLR_RESET} (${expected_id})"
            echo -e "${_CLR_DIM}  AWS Access Portal → Select this account → 'Command line or"
            echo -e "  programmatic access' → Copy Option 1 (environment variables)${_CLR_RESET}"
            echo -e "${_CLR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_RESET}"
            echo ""
            echo "  Paste the export commands below (press Enter twice when done):"
            echo ""

            pasted_text=""
            empty_count=0
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then
                    empty_count=$((empty_count + 1))
                    [[ $empty_count -ge 1 ]] && break
                else
                    empty_count=0
                    pasted_text+="$line"$'\n'
                fi
            done

            # Parse credentials — extract value after the = sign, strip quotes
            access_key=$(echo "$pasted_text" | grep 'AWS_ACCESS_KEY_ID' | sed 's/^[^=]*=//' | tr -d '"' | tr -d "'" | xargs)
            secret_key=$(echo "$pasted_text" | grep 'AWS_SECRET_ACCESS_KEY' | sed 's/^[^=]*=//' | tr -d '"' | tr -d "'" | xargs)
            session_token=$(echo "$pasted_text" | grep 'AWS_SESSION_TOKEN' | sed 's/^[^=]*=//' | tr -d '"' | tr -d "'" | xargs)

            if [[ -z "$access_key" || -z "$secret_key" ]]; then
                error "Could not parse credentials. Please paste the export lines from the portal."
                continue
            fi

            # Verify these creds point to the right account
            # CloudShell uses container credentials (AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)
            # which override env vars. We must unset it to force env var usage.
            _ORIG_AK="${AWS_ACCESS_KEY_ID:-}"
            _ORIG_SK="${AWS_SECRET_ACCESS_KEY:-}"
            _ORIG_ST="${AWS_SESSION_TOKEN:-}"
            _ORIG_CONTAINER_CREDS="${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}"
            export AWS_ACCESS_KEY_ID="$access_key"
            export AWS_SECRET_ACCESS_KEY="$secret_key"
            export AWS_SESSION_TOKEN="$session_token"
            export AWS_EC2_METADATA_DISABLED=true
            unset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI 2>/dev/null || true

            actual_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null) || actual_id=""

            # Restore original creds and container URI
            export AWS_ACCESS_KEY_ID="$_ORIG_AK"
            export AWS_SECRET_ACCESS_KEY="$_ORIG_SK"
            export AWS_SESSION_TOKEN="$_ORIG_ST"
            if [[ -n "$_ORIG_CONTAINER_CREDS" ]]; then
                export AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="$_ORIG_CONTAINER_CREDS"
            fi
            unset AWS_EC2_METADATA_DISABLED

            if [[ "$actual_id" != "$expected_id" ]]; then
                error "Account mismatch! Expected: $expected_id, Got: ${actual_id:-<auth failed>}"
                error "Please paste credentials for the correct account."
                continue
            fi

            ok "$account_label ($expected_id) — verified ✓"
            CREDS_ACCESS_KEY["$acct_context"]="$access_key"
            CREDS_SECRET_KEY["$acct_context"]="$secret_key"
            CREDS_SESSION_TOKEN["$acct_context"]="$session_token"
            break
        done
    done

    echo ""
    ok "All account credentials collected and verified"
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

    # Skip completed steps
    if is_step_complete "$STATE_FILE" "$step_id"; then
        info "[Step ${STEP_NUM}/${TOTAL_STEPS}] ${STEP_LABELS[$step_id]:-$step_id} — already complete, skipping"
        continue
    fi

    step_label="${STEP_LABELS[$step_id]:-$step_id}"
    step_account="${STEP_ACCOUNT[$step_id]:-unknown}"

    # Switch credentials if account context changed
    if [[ "$step_account" != "$CURRENT_ACCOUNT" ]]; then
        account_label="${ACCOUNT_LABELS[$step_account]:-$step_account}"

        # Apply stored credentials for this account
        if [[ "${CREDS_ACCESS_KEY[$step_account]:-}" == "__current__" ]]; then
            # Restore container credentials for current account
            # Must unset explicit creds so container/instance profile takes over
            unset AWS_ACCESS_KEY_ID 2>/dev/null || true
            unset AWS_SECRET_ACCESS_KEY 2>/dev/null || true
            unset AWS_SESSION_TOKEN 2>/dev/null || true
            if [[ -n "${_ORIG_CONTAINER_CREDS:-}" ]]; then
                export AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="$_ORIG_CONTAINER_CREDS"
            fi
            unset AWS_EC2_METADATA_DISABLED 2>/dev/null || true
            info "Using current credentials for $account_label"
        elif [[ -n "${CREDS_ACCESS_KEY[$step_account]:-}" ]]; then
            export AWS_ACCESS_KEY_ID="${CREDS_ACCESS_KEY[$step_account]}"
            export AWS_SECRET_ACCESS_KEY="${CREDS_SECRET_KEY[$step_account]}"
            export AWS_SESSION_TOKEN="${CREDS_SESSION_TOKEN[$step_account]}"
            export AWS_EC2_METADATA_DISABLED=true
            unset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI 2>/dev/null || true
            info "Switched to: $account_label"
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

    # Execute step script — stream output in real-time using tee
    step_output_file="/tmp/cdx-step-output-$$.txt"
    step_exit_code=0
    bash "$step_script" 2>&1 | tee "$step_output_file" || step_exit_code=$?
    step_output=$(cat "$step_output_file")
    rm -f "$step_output_file"

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
echo "  To tear down: ./setup.sh --cleanup"
echo ""
