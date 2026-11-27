#!/usr/bin/env bats
# =============================================================================
# Unit Tests: Progress Display and Error Handling
# =============================================================================

setup() {
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
}

# --- show_progress ---

@test "show_progress displays step N/M format" {
    result=$(show_progress 1 8 "Sync ECR")
    [[ "$result" =~ "[Step 1/8]" ]]
}

@test "show_progress shows percentage" {
    result=$(show_progress 4 8 "Accept Peering")
    [[ "$result" =~ "(50%)" ]]
}

@test "show_progress shows step name" {
    result=$(show_progress 3 5 "Install Workloads")
    [[ "$result" =~ "Install Workloads" ]]
}

@test "show_progress at 100%" {
    result=$(show_progress 5 5 "Done")
    [[ "$result" =~ "(100%)" ]]
}

# --- require_env ---

@test "require_env succeeds when all vars are set" {
    export TEST_VAR1="hello"
    export TEST_VAR2="world"
    require_env TEST_VAR1 TEST_VAR2
}

@test "require_env fails when var is missing" {
    unset MISSING_VAR 2>/dev/null || true
    run require_env MISSING_VAR
    [ "$status" -ne 0 ]
}

@test "require_env reports missing var name in error" {
    unset MY_MISSING 2>/dev/null || true
    result=$(require_env MY_MISSING 2>&1) || true
    [[ "$result" =~ "MY_MISSING" ]]
}

@test "require_env fails when var is empty" {
    export EMPTY_VAR=""
    run require_env EMPTY_VAR
    [ "$status" -ne 0 ]
}

# --- check_prerequisites ---

@test "check_prerequisites succeeds for available commands" {
    check_prerequisites "bash" "echo"
}

@test "check_prerequisites fails for missing command" {
    run check_prerequisites "nonexistent_command_xyz_123"
    [ "$status" -ne 0 ]
}

@test "check_prerequisites reports missing command name" {
    result=$(check_prerequisites "fake_tool_abc" 2>&1) || true
    [[ "$result" =~ "fake_tool_abc" ]]
}
