#!/usr/bin/env bash
# =============================================================================
# CDX JIT Setup Orchestrator — Shared Library
# =============================================================================
# This library is sourced by all orchestrators and step scripts. It provides:
#   - Logging functions (log, ok, info, warn, error, step)
#   - Prompt functions (prompt_with_default, prompt_yes_no, prompt_selection)
#   - State management (save_state, load_state, mark_step_complete, etc.)
#   - Account verification (verify_aws_account, verify_azure_subscription)
#   - Validation functions (validate_aws_account_id, validate_cidr, etc.)
#   - Error handling (handle_error trap)
#   - Progress display (show_progress)
#   - OUTPUT protocol parsing (parse_step_output)
#   - Sensitive value masking (mask_sensitive)
# =============================================================================

# Prevent double-sourcing
if [[ "${_CDX_COMMON_LOADED:-}" == "true" ]]; then
    return 0
fi
_CDX_COMMON_LOADED="true"

# =============================================================================
# STANDARD RESOURCE TAGS
# =============================================================================
# All created resources are tagged with a consistent set. The purpose value is
# product-specific and set via CDX_PURPOSE (e.g. jit_db, jit_k8s, jit_vm).
# Environment is hardcoded to Prod.
#
# Different AWS CLI commands need different tag formats — these helpers emit
# the right shape:
#   cdx_tags_ec2   → for --tag-specifications inner Tags list (EC2/VPC/EFS specs)
#                    "{Key=Environment,Value=Prod},{Key=Created_by,Value=Cloudanix},..."
#   cdx_tags_kv    → for --tags on IAM/EFS/Secrets (space-separated Key=..,Value=..)
#                    "Key=Environment,Value=Prod Key=Created_by,Value=Cloudanix ..."
#   cdx_tags_ecs   → for ECS --tags (lowercase key/value)
#                    "key=Environment,value=Prod key=Created_by,value=Cloudanix ..."
#   cdx_tags_json  → JSON array [{"Key":..,"Value":..}, ...]  (task defs, some APIs)
#   cdx_tags_json_lc → JSON array with lowercase key/value (ECS task-def "tags")
# =============================================================================

cdx_purpose() { echo "${CDX_PURPOSE:-jit}"; }

cdx_tags_ec2() {
    local extra="${1:-}"  # optional leading "{Key=Name,Value=x}," prefix caller can pass
    echo "${extra}{Key=Environment,Value=Prod},{Key=Created_by,Value=Cloudanix},{Key=purpose,Value=$(cdx_purpose)}"
}

cdx_tags_kv() {
    echo "Key=Environment,Value=Prod Key=Created_by,Value=Cloudanix Key=purpose,Value=$(cdx_purpose)"
}

cdx_tags_ecs() {
    echo "key=Environment,value=Prod key=Created_by,value=Cloudanix key=purpose,value=$(cdx_purpose)"
}

cdx_tags_json() {
    printf '[{"Key":"Environment","Value":"Prod"},{"Key":"Created_by","Value":"Cloudanix"},{"Key":"purpose","Value":"%s"}]' "$(cdx_purpose)"
}

cdx_tags_json_lc() {
    printf '[{"key":"Environment","value":"Prod"},{"key":"Created_by","value":"Cloudanix"},{"key":"purpose","value":"%s"}]' "$(cdx_purpose)"
}

# =============================================================================
# COLOR DETECTION
# =============================================================================

# Determine if we should use colors
_CDX_USE_COLOR="false"
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ "${NO_COLOR:-}" == "" ]]; then
    _CDX_USE_COLOR="true"
fi

# Define color codes (empty if no color support)
if [[ "$_CDX_USE_COLOR" == "true" ]]; then
    _CLR_RESET="\033[0m"
    _CLR_RED="\033[0;31m"
    _CLR_GREEN="\033[0;32m"
    _CLR_YELLOW="\033[0;33m"
    _CLR_BLUE="\033[0;34m"
    _CLR_CYAN="\033[0;36m"
    _CLR_BOLD="\033[1m"
    _CLR_DIM="\033[2m"
else
    _CLR_RESET=""
    _CLR_RED=""
    _CLR_GREEN=""
    _CLR_YELLOW=""
    _CLR_BLUE=""
    _CLR_CYAN=""
    _CLR_BOLD=""
    _CLR_DIM=""
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
# Format: [HH:MM:SS] [SEVERITY] message
# Colors applied when stdout is a TTY and TERM is not "dumb"
# =============================================================================

_timestamp() {
    date +'%H:%M:%S'
}

log() {
    echo -e "${_CLR_DIM}[$(_timestamp)]${_CLR_RESET} ${_CLR_BLUE}[INFO]${_CLR_RESET} $*"
}

ok() {
    echo -e "${_CLR_DIM}[$(_timestamp)]${_CLR_RESET} ${_CLR_GREEN}[OK]${_CLR_RESET} $*"
}

info() {
    echo -e "${_CLR_DIM}[$(_timestamp)]${_CLR_RESET} ${_CLR_BLUE}[INFO]${_CLR_RESET} $*"
}

warn() {
    echo -e "${_CLR_DIM}[$(_timestamp)]${_CLR_RESET} ${_CLR_YELLOW}[WARN]${_CLR_RESET} $*"
}

error() {
    echo -e "${_CLR_DIM}[$(_timestamp)]${_CLR_RESET} ${_CLR_RED}[ERROR]${_CLR_RESET} $*" >&2
}

step() {
    echo ""
    echo -e "${_CLR_DIM}[$(_timestamp)]${_CLR_RESET} ${_CLR_BOLD}${_CLR_CYAN}[STEP]${_CLR_RESET} ${_CLR_BOLD}━━━ $* ━━━${_CLR_RESET}"
}

# =============================================================================
# PROMPT FUNCTIONS
# =============================================================================

# prompt_with_default PROMPT DEFAULT_VALUE
#   Displays: "PROMPT [DEFAULT_VALUE]: "
#   Returns: user input or default if empty
prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local user_input
    # -e enables readline editing so Backspace/Delete/arrow keys work correctly
    # (without it, Backspace is captured literally as ^? / 0x7F)
    read -erp "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# prompt_yes_no PROMPT DEFAULT(y/n)
#   Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    local yn
    local attempts=0
    while true; do
        read -erp "$prompt (y/n) [$default_value]: " yn
        yn="${yn:-$default_value}"
        case "$yn" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * )
                attempts=$((attempts + 1))
                if [[ $attempts -ge 3 ]]; then
                    error "Too many invalid attempts. Defaulting to '$default_value'."
                    case "$default_value" in
                        [Yy]* ) return 0;;
                        * ) return 1;;
                    esac
                fi
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
}

# prompt_selection PROMPT OPTIONS_ARRAY_NAME
#   Displays numbered menu, returns selected value via global CDX_SELECTED
#   Retries up to 3 times on invalid input, then exits
#   NOTE: Sets CDX_SELECTED global variable (not stdout) to avoid capture issues
prompt_selection() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local attempts=0

    echo ""
    echo "$prompt"
    echo ""
    for i in "${!options[@]}"; do
        echo "  $((i + 1))) ${options[$i]}"
    done
    echo ""

    while true; do
        local choice
        read -erp "Select option [1-$count]: " choice

        # Validate: must be a number in range
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            CDX_SELECTED="${options[$((choice - 1))]}"
            return 0
        fi

        attempts=$((attempts + 1))
        if [[ $attempts -ge 3 ]]; then
            error "Too many invalid attempts. Please enter a number between 1 and $count."
            return 1
        fi
        warn "Invalid selection. Please enter a number between 1 and $count."
    done
}

# =============================================================================
# CREDENTIAL CAPTURE
# =============================================================================
# Capturing AWS temporary credentials interactively is surprisingly hard: the
# session token is ~1KB and a single pasted line can exceed the terminal's
# canonical-mode input limit (~1024 bytes on macOS), silently truncating it.
# To be robust, we open a temp file in the user's editor so they can paste the
# full block with no length limit, then parse the saved file.
#
# capture_aws_creds_via_editor OUT_AK OUT_SK OUT_ST
#   Reads three variable NAMES and assigns the parsed values into them.
#   Returns 0 on success (access key + secret present), 1 otherwise.
# =============================================================================
# _cdx_strip_cred_value RAW
#   Normalizes a single pasted credential entry: removes a leading "export ",
#   strips an "AWS_...=" prefix if the whole export line was pasted, removes
#   surrounding quotes and CR/whitespace. Prints the cleaned value.
_cdx_strip_cred_value() {
    local _val="$1"
    _val="${_val#export }"
    if [[ "$_val" == AWS_*=* ]]; then
        _val="${_val#*=}"
    fi
    _val="${_val%$'\r'}"
    printf '%s' "$_val" | tr -d '"' | tr -d "'" | xargs
}

# capture_aws_creds_per_field OUT_AK OUT_SK OUT_ST
#   Prompts for each credential value on its own line and assigns the parsed
#   values into the named variables. Entering one value per prompt keeps each
#   input short enough to avoid the terminal's canonical-mode line-length limit
#   that truncates a pasted multi-line export block. Accepts either a bare value
#   or a full 'export KEY="value"' line. Returns 0 if AK+SK are present.
capture_aws_creds_per_field() {
    local _ak_var="$1" _sk_var="$2" _st_var="$3"
    local _ak_in _sk_in _st_in
    read -erp "  AWS_ACCESS_KEY_ID: " _ak_in
    read -erp "  AWS_SECRET_ACCESS_KEY: " _sk_in
    read -erp "  AWS_SESSION_TOKEN: " _st_in
    printf -v "$_ak_var" '%s' "$(_cdx_strip_cred_value "$_ak_in")"
    printf -v "$_sk_var" '%s' "$(_cdx_strip_cred_value "$_sk_in")"
    printf -v "$_st_var" '%s' "$(_cdx_strip_cred_value "$_st_in")"
    [[ -n "${!_ak_var}" && -n "${!_sk_var}" ]]
}

capture_aws_creds_via_editor() {
    local _ak_var="$1" _sk_var="$2" _st_var="$3"
    local _tmp
    _tmp="$(mktemp "${TMPDIR:-/tmp}/cdx-creds.XXXXXX")" || return 1
    # Ensure the temp file is removed even if the editor or parsing fails.
    chmod 600 "$_tmp" 2>/dev/null || true

    cat > "$_tmp" << 'TEMPLATE'
# Paste the three export lines from the AWS Access Portal below this comment,
# then SAVE and CLOSE this file to continue.
#   AWS Access Portal -> your account -> "Command line or programmatic access"
#   -> copy "Option 1: Set AWS environment variables" (all three lines).
#
# Lines starting with '#' are ignored. Example of what to paste:
#   export AWS_ACCESS_KEY_ID="ASIA..."
#   export AWS_SECRET_ACCESS_KEY="..."
#   export AWS_SESSION_TOKEN="..."

TEMPLATE

    local _editor="${EDITOR:-${VISUAL:-}}"
    if [[ -z "$_editor" ]]; then
        # Pick a sensible default that exists on the system.
        if command -v nano >/dev/null 2>&1; then _editor="nano"
        elif command -v vim  >/dev/null 2>&1; then _editor="vim"
        elif command -v vi   >/dev/null 2>&1; then _editor="vi"
        else _editor=""; fi
    fi

    if [[ -n "$_editor" ]]; then
        info "Opening an editor ($_editor). Paste the 3 lines, then save & close."
        # Give the user a moment to read the message.
        sleep 1
        "$_editor" "$_tmp" </dev/tty >/dev/tty 2>&1 || true
    else
        warn "No editor found. Edit this file, paste the 3 lines, save, then press Enter:"
        echo "    $_tmp"
        read -r _ </dev/tty || true
    fi

    local _content
    _content="$(cat "$_tmp" 2>/dev/null)"
    rm -f "$_tmp" 2>/dev/null || true

    # Strip comment lines, then extract each value.
    local _clean
    _clean="$(printf '%s\n' "$_content" | grep -v '^[[:space:]]*#')"
    local _ak _sk _st
    _ak=$(printf '%s\n' "$_clean" | grep 'AWS_ACCESS_KEY_ID'     | tail -n1 | sed 's/^[^=]*=//' | tr -d '"' | tr -d "'" | xargs)
    _sk=$(printf '%s\n' "$_clean" | grep 'AWS_SECRET_ACCESS_KEY' | tail -n1 | sed 's/^[^=]*=//' | tr -d '"' | tr -d "'" | xargs)
    _st=$(printf '%s\n' "$_clean" | grep 'AWS_SESSION_TOKEN'     | tail -n1 | sed 's/^[^=]*=//' | tr -d '"' | tr -d "'" | xargs)

    printf -v "$_ak_var" '%s' "$_ak"
    printf -v "$_sk_var" '%s' "$_sk"
    printf -v "$_st_var" '%s' "$_st"

    [[ -n "$_ak" && -n "$_sk" ]]
}

# =============================================================================
# STATE MANAGEMENT FUNCTIONS
# =============================================================================
# State is stored as JSON in .state.json using jq for manipulation.
# All writes are atomic: write to .state.json.tmp then mv.
# =============================================================================

# Initialize a new state file
# init_state STATE_FILE SETUP_TYPE SCOPE_MODE
init_state() {
    local state_file="$1"
    local setup_type="$2"
    local scope_mode="$3"
    local started_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq -n \
        --arg version "1" \
        --arg setup_type "$setup_type" \
        --arg scope_mode "$scope_mode" \
        --arg started_at "$started_at" \
        '{
            version: ($version | tonumber),
            setup_type: $setup_type,
            scope_mode: $scope_mode,
            started_at: $started_at,
            config: {},
            steps: {}
        }' > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
}

# save_state STATE_FILE JSON_CONTENT
#   Atomic write: writes to temp file then renames
save_state() {
    local state_file="$1"
    local content="$2"
    echo "$content" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
}

# load_state STATE_FILE
#   Reads and validates state file. Outputs JSON to stdout.
#   Returns 0 if valid, 1 if corrupt/missing
load_state() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    local content
    content=$(cat "$state_file")

    # Validate it's valid JSON with required fields
    if ! echo "$content" | jq -e '.version and .setup_type and .scope_mode and .config and .steps' > /dev/null 2>&1; then
        return 1
    fi

    echo "$content"
    return 0
}

# mark_step_complete STATE_FILE STEP_ID OUTPUTS_JSON
#   Records step completion with timestamp and outputs
mark_step_complete() {
    local state_file="$1"
    local step_id="$2"
    local outputs_json="${3:-\{\}}"
    local completed_at
    completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Validate outputs_json is valid JSON, default to empty object if not
    if ! echo "$outputs_json" | jq . > /dev/null 2>&1; then
        outputs_json="{}"
    fi

    local current_state
    current_state=$(cat "$state_file")

    local new_state
    new_state=$(echo "$current_state" | jq \
        --arg step_id "$step_id" \
        --arg completed_at "$completed_at" \
        --argjson outputs "$outputs_json" \
        '.steps[$step_id] = {status: "complete", completed_at: $completed_at, outputs: $outputs}')

    save_state "$state_file" "$new_state"
}

# is_step_complete STATE_FILE STEP_ID
#   Returns 0 if step is marked complete, 1 otherwise
is_step_complete() {
    local state_file="$1"
    local step_id="$2"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    local status
    status=$(jq -r --arg step_id "$step_id" '.steps[$step_id].status // "incomplete"' "$state_file")

    if [[ "$status" == "complete" ]]; then
        return 0
    fi
    return 1
}

# get_step_output STATE_FILE STEP_ID KEY
#   Returns the output value for a completed step
get_step_output() {
    local state_file="$1"
    local step_id="$2"
    local key="$3"

    jq -r --arg step_id "$step_id" --arg key "$key" \
        '.steps[$step_id].outputs[$key] // ""' "$state_file"
}

# set_config_value STATE_FILE KEY VALUE
#   Stores a configuration value in the state file
set_config_value() {
    local state_file="$1"
    local key="$2"
    local value="$3"

    local current_state
    current_state=$(cat "$state_file")

    local new_state
    new_state=$(echo "$current_state" | jq \
        --arg key "$key" \
        --arg value "$value" \
        '.config[$key] = $value')

    save_state "$state_file" "$new_state"
}

# get_config_value STATE_FILE KEY
#   Retrieves a configuration value from state
get_config_value() {
    local state_file="$1"
    local key="$2"

    jq -r --arg key "$key" '.config[$key] // ""' "$state_file"
}

# =============================================================================
# ACCOUNT VERIFICATION FUNCTIONS
# =============================================================================

# prompt_aws_credentials ACCOUNT_LABEL EXPECTED_ACCOUNT_ID
#   Prompts the user to paste temporary AWS credentials from the access portal.
#   Parses the pasted text for AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#   and AWS_SESSION_TOKEN, exports them, then verifies the account ID.
#   Returns 0 on success, 1 on failure.
prompt_aws_credentials() {
    local account_label="$1"
    local expected_id="$2"

    echo ""
    echo -e "${_CLR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_RESET}"
    echo -e "${_CLR_BOLD}  Paste credentials for: ${account_label} (${expected_id})${_CLR_RESET}"
    echo -e "${_CLR_DIM}  Go to AWS Access Portal → Select account → 'Command line or"
    echo -e "  programmatic access' → Copy Option 1 (environment variables)${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_RESET}"
    echo ""
    echo -e "  Paste the export commands below (press Enter twice when done):"
    echo ""

    local pasted_text=""
    local empty_lines=0

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            empty_lines=$((empty_lines + 1))
            if [[ $empty_lines -ge 1 ]]; then
                break
            fi
        else
            empty_lines=0
            pasted_text+="$line"$'\n'
        fi
    done

    # Parse credentials from pasted text
    local access_key secret_key session_token

    access_key=$(echo "$pasted_text" | grep -oP '(?<=AWS_ACCESS_KEY_ID=")[^"]+' 2>/dev/null || \
                 echo "$pasted_text" | grep 'AWS_ACCESS_KEY_ID' | sed 's/.*="\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' "' | head -1)

    secret_key=$(echo "$pasted_text" | grep -oP '(?<=AWS_SECRET_ACCESS_KEY=")[^"]+' 2>/dev/null || \
                 echo "$pasted_text" | grep 'AWS_SECRET_ACCESS_KEY' | sed 's/.*="\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' "' | head -1)

    session_token=$(echo "$pasted_text" | grep -oP '(?<=AWS_SESSION_TOKEN=")[^"]+' 2>/dev/null || \
                    echo "$pasted_text" | grep 'AWS_SESSION_TOKEN' | sed 's/.*="\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' "' | head -1)

    if [[ -z "$access_key" || -z "$secret_key" ]]; then
        error "Could not parse AWS credentials from pasted text."
        error "Expected format:"
        error '  export AWS_ACCESS_KEY_ID="AKIA..."'
        error '  export AWS_SECRET_ACCESS_KEY="..."'
        error '  export AWS_SESSION_TOKEN="..."'
        return 1
    fi

    # Export the credentials
    export AWS_ACCESS_KEY_ID="$access_key"
    export AWS_SECRET_ACCESS_KEY="$secret_key"
    export AWS_SESSION_TOKEN="${session_token:-}"

    # Verify we're in the right account
    local actual_id
    actual_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null) || {
        error "Credentials invalid — could not call AWS STS."
        return 1
    }

    if [[ "$actual_id" != "$expected_id" ]]; then
        error "Account mismatch!"
        error "  Expected: $expected_id ($account_label)"
        error "  Got:      $actual_id"
        error "  Please paste credentials for the correct account."
        return 1
    fi

    ok "Credentials verified: $account_label ($actual_id)"
    return 0
}

# switch_aws_account EXPECTED_ACCOUNT_ID ACCOUNT_LABEL
#   High-level account switch handler.
#   Checks if already in the right account, otherwise prompts for credentials.
#   Retries up to 3 times on failure.
switch_aws_account() {
    local expected_id="$1"
    local account_label="${2:-Account $expected_id}"

    # Check if we're already in the right account
    local current_id
    current_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null) || current_id=""

    if [[ "$current_id" == "$expected_id" ]]; then
        ok "Already in account: $account_label ($expected_id)"
        return 0
    fi

    # Prompt for credentials (retry up to 3 times)
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
        if prompt_aws_credentials "$account_label" "$expected_id"; then
            return 0
        fi
        attempts=$((attempts + 1))
        if [[ $attempts -lt 3 ]]; then
            warn "Retry $attempts/3..."
        fi
    done

    error "Failed to switch to $account_label after 3 attempts."
    return 1
}

# verify_aws_account EXPECTED_ACCOUNT_ID
#   Returns 0 if current AWS account matches expected, 1 otherwise
#   Outputs actual account ID on mismatch
verify_aws_account() {
    local expected_id="$1"
    local actual_id

    actual_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null) || {
        error "Failed to get AWS caller identity. Are AWS credentials configured?"
        return 1
    }

    if [[ "$actual_id" == "$expected_id" ]]; then
        return 0
    fi

    echo "$actual_id"
    return 1
}

# verify_azure_subscription EXPECTED_SUBSCRIPTION_ID
#   Returns 0 if current Azure subscription matches expected, 1 otherwise
#   Outputs actual subscription ID on mismatch
verify_azure_subscription() {
    local expected_id="$1"
    local actual_id

    actual_id=$(az account show --query "id" --output tsv 2>/dev/null) || {
        error "Failed to get Azure subscription. Are you logged in with 'az login'?"
        return 1
    }

    if [[ "$actual_id" == "$expected_id" ]]; then
        return 0
    fi

    echo "$actual_id"
    return 1
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================
# Each validator returns 0 on match, 1 on mismatch

validate_aws_account_id() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{12}$ ]]
}

validate_azure_subscription_id() {
    local value="$1"
    [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

validate_cidr() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]
}

validate_arn() {
    local value="$1"
    [[ "$value" =~ ^arn:aws[a-zA-Z-]*:[a-zA-Z0-9-]+:[a-zA-Z0-9-]*:[0-9]*:.+ ]]
}

validate_region() {
    local value="$1"
    local known_regions="us-east-1 us-east-2 us-west-1 us-west-2 af-south-1 ap-east-1 ap-south-1 ap-south-2 ap-southeast-1 ap-southeast-2 ap-southeast-3 ap-northeast-1 ap-northeast-2 ap-northeast-3 ca-central-1 eu-central-1 eu-central-2 eu-west-1 eu-west-2 eu-west-3 eu-south-1 eu-south-2 eu-north-1 me-south-1 me-central-1 sa-east-1 il-central-1"
    [[ " $known_regions " == *" $value "* ]]
}

validate_alphanumeric_dash() {
    local value="$1"
    [[ "$value" =~ ^[a-zA-Z0-9-]+$ ]]
}

validate_semver_or_latest() {
    local value="$1"
    [[ "$value" == "latest" ]] || [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]
}

validate_boolean() {
    local value="$1"
    [[ "$value" == "true" || "$value" == "false" ]]
}

validate_nonempty() {
    local value="$1"
    [[ -n "$value" ]]
}

# Dispatcher: validate VALUE RULE
#   Calls the appropriate validator based on rule name
validate() {
    local value="$1"
    local rule="$2"

    case "$rule" in
        aws_account_id)         validate_aws_account_id "$value" ;;
        azure_subscription_id)  validate_azure_subscription_id "$value" ;;
        cidr)                   validate_cidr "$value" ;;
        arn)                    validate_arn "$value" ;;
        region)                 validate_region "$value" ;;
        alphanumeric_dash)      validate_alphanumeric_dash "$value" ;;
        semver_or_latest)       validate_semver_or_latest "$value" ;;
        boolean)                validate_boolean "$value" ;;
        nonempty)               validate_nonempty "$value" ;;
        *)                      validate_nonempty "$value" ;;  # fallback
    esac
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

# handle_error LINE_NUMBER EXIT_CODE
#   ERR trap handler — logs line number and exit code, then exits
handle_error() {
    local line_number="${1:-unknown}"
    local exit_code="${2:-$?}"
    error "Script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

# =============================================================================
# PROGRESS DISPLAY
# =============================================================================

# show_progress CURRENT_STEP TOTAL_STEPS STEP_NAME
#   Displays: [Step N/M] (XX%) step_name
show_progress() {
    local current="$1"
    local total="$2"
    local step_name="$3"
    local pct=$(( (current * 100) / total ))

    echo ""
    echo -e "${_CLR_BOLD}[Step ${current}/${total}]${_CLR_RESET} (${pct}%) ${_CLR_CYAN}${step_name}${_CLR_RESET}"
    echo -e "${_CLR_DIM}$(printf '─%.0s' $(seq 1 60))${_CLR_RESET}"
}

# =============================================================================
# SENSITIVE VALUE MASKING
# =============================================================================

# mask_sensitive VALUE
#   Masks all but last 4 characters with asterisks
#   If value is 4 chars or fewer, shows all asterisks
mask_sensitive() {
    local value="$1"
    local len=${#value}

    if [[ $len -le 4 ]]; then
        printf '%*s' "$len" '' | tr ' ' '*'
    else
        local visible="${value: -4}"
        local masked_len=$((len - 4))
        printf '%*s' "$masked_len" '' | tr ' ' '*'
        echo -n "$visible"
    fi
    echo ""
}

# =============================================================================
# OUTPUT PROTOCOL PARSING
# =============================================================================

# parse_step_output STDOUT_CONTENT
#   Extracts valid OUTPUT:<KEY>=<VALUE> lines from step script stdout
#   Outputs JSON object of key-value pairs
#   Logs warnings for malformed OUTPUT: lines
parse_step_output() {
    local content="$1"
    local result="{}"

    while IFS= read -r line; do
        # Check if line starts with OUTPUT:
        if [[ "$line" == OUTPUT:* ]]; then
            local payload="${line#OUTPUT:}"
            # Extract KEY and VALUE from KEY=VALUE format
            if [[ "$payload" == *=* ]]; then
                local key="${payload%%=*}"
                local value="${payload#*=}"
                # Validate KEY format: starts with uppercase letter, alphanumeric + underscore, max 64 chars
                if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && [[ ${#key} -le 64 ]] && [[ ${#value} -le 256 ]]; then
                    result=$(echo "$result" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
                else
                    warn "Malformed OUTPUT line: $line"
                fi
            else
                warn "Malformed OUTPUT line: $line"
            fi
        fi
    done <<< "$content"

    echo "$result"
}

# =============================================================================
# ACCOUNT SWITCH BANNER
# =============================================================================

# show_account_switch_banner ACCOUNT_LABEL ACCOUNT_ID NEXT_STEP_NAME
#   Displays a prominent colored banner for account context switches
show_account_switch_banner() {
    local account_label="$1"
    local account_id="$2"
    local next_step="$3"

    echo ""
    echo -e "${_CLR_YELLOW}╔══════════════════════════════════════════════════════════════════╗${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}║${_CLR_RESET}  ${_CLR_BOLD}⚠  ACCOUNT SWITCH REQUIRED${_CLR_RESET}                                     ${_CLR_YELLOW}║${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}╠══════════════════════════════════════════════════════════════════╣${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}║${_CLR_RESET}                                                                  ${_CLR_YELLOW}║${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}║${_CLR_RESET}  Switch to: ${_CLR_BOLD}${account_label}${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}║${_CLR_RESET}  Account:   ${_CLR_CYAN}${account_id}${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}║${_CLR_RESET}  Next step: ${next_step}"
    echo -e "${_CLR_YELLOW}║${_CLR_RESET}                                                                  ${_CLR_YELLOW}║${_CLR_RESET}"
    echo -e "${_CLR_YELLOW}╚══════════════════════════════════════════════════════════════════╝${_CLR_RESET}"
    echo ""
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# check_prerequisites COMMANDS...
#   Verifies all required commands are available
check_prerequisites() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        error "Please install them before proceeding."
        return 1
    fi
    return 0
}

# =============================================================================
# REQUIRE ENVIRONMENT VARIABLES
# =============================================================================

# require_env VAR_NAME...
#   Checks that all named environment variables are set and non-empty
#   Exits with error if any are missing
require_env() {
    local missing=()
    for var_name in "$@"; do
        if [[ -z "${!var_name:-}" ]]; then
            missing+=("$var_name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required environment variables: ${missing[*]}"
        return 1
    fi
    return 0
}

# =============================================================================
# EXPORT ALL FUNCTIONS
# =============================================================================

export -f _timestamp log ok info warn error step
export -f prompt_with_default prompt_yes_no prompt_selection
export -f init_state save_state load_state mark_step_complete is_step_complete
export -f get_step_output set_config_value get_config_value
export -f verify_aws_account verify_azure_subscription
export -f prompt_aws_credentials switch_aws_account
export -f validate_aws_account_id validate_azure_subscription_id validate_cidr
export -f validate_arn validate_region validate_alphanumeric_dash
export -f validate_semver_or_latest validate_boolean validate_nonempty validate
export -f handle_error show_progress mask_sensitive parse_step_output
export -f show_account_switch_banner check_prerequisites require_env
