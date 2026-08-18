#!/usr/bin/env bats
# =============================================================================
# Unit Tests: Logging Functions
# =============================================================================

setup() {
    export TERM="xterm-256color"
    export NO_COLOR=""
    # Force reload
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
}

@test "log() outputs [HH:MM:SS] [INFO] format" {
    result=$(log "test message" 2>&1)
    [[ "$result" =~ \[[0-9]{2}:[0-9]{2}:[0-9]{2}\] ]]
    [[ "$result" =~ \[INFO\] ]]
    [[ "$result" =~ "test message" ]]
}

@test "ok() outputs [HH:MM:SS] [OK] format" {
    result=$(ok "success message" 2>&1)
    [[ "$result" =~ \[[0-9]{2}:[0-9]{2}:[0-9]{2}\] ]]
    [[ "$result" =~ \[OK\] ]]
    [[ "$result" =~ "success message" ]]
}

@test "info() outputs [HH:MM:SS] [INFO] format" {
    result=$(info "info message" 2>&1)
    [[ "$result" =~ \[INFO\] ]]
    [[ "$result" =~ "info message" ]]
}

@test "warn() outputs [HH:MM:SS] [WARN] format" {
    result=$(warn "warning message" 2>&1)
    [[ "$result" =~ \[WARN\] ]]
    [[ "$result" =~ "warning message" ]]
}

@test "error() outputs [HH:MM:SS] [ERROR] to stderr" {
    result=$(error "error message" 2>&1)
    [[ "$result" =~ \[ERROR\] ]]
    [[ "$result" =~ "error message" ]]
}

@test "step() outputs [HH:MM:SS] [STEP] with separators" {
    result=$(step "Test Step" 2>&1)
    [[ "$result" =~ \[STEP\] ]]
    [[ "$result" =~ "━━━ Test Step ━━━" ]]
}

@test "logging without color when NO_COLOR is set" {
    export NO_COLOR="1"
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
    result=$(log "plain message" 2>&1)
    # Should not contain ANSI escape codes
    [[ ! "$result" =~ $'\033' ]]
    [[ "$result" =~ \[INFO\] ]]
}

@test "logging without color when TERM is dumb" {
    export TERM="dumb"
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
    result=$(log "plain message" 2>&1)
    [[ "$result" =~ \[INFO\] ]]
}
