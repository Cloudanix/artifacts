#!/usr/bin/env bats
# =============================================================================
# Integration Tests: Orchestrator Flow (with mock CLI)
# =============================================================================

setup() {
    export TEST_DIR=$(mktemp -d)
    export MOCK_DIR="$TEST_DIR/mocks"
    mkdir -p "$MOCK_DIR"

    # Create mock aws CLI
    cat > "$MOCK_DIR/aws" << 'MOCK'
#!/usr/bin/env bash
# Mock AWS CLI — responds based on arguments
case "$*" in
    *"sts get-caller-identity"*"--query"*"Account"*)
        echo "123456789012"
        ;;
    *"sts get-caller-identity"*)
        echo '{"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/test"}'
        ;;
    *) echo "mock-output" ;;
esac
MOCK
    chmod +x "$MOCK_DIR/aws"

    # Create mock docker
    cat > "$MOCK_DIR/docker" << 'MOCK'
#!/usr/bin/env bash
echo "mock-docker: $*" > /dev/null
MOCK
    chmod +x "$MOCK_DIR/docker"

    # Prepend mocks to PATH
    export PATH="$MOCK_DIR:$PATH"

    # Copy orchestrator files to test dir
    cp -r "$BATS_TEST_DIRNAME/../../lib" "$TEST_DIR/"
    cp -r "$BATS_TEST_DIRNAME/../../aws-jit-db" "$TEST_DIR/"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "setup.sh exits with error when lib/common.sh is missing" {
    rm -f "$TEST_DIR/lib/common.sh"
    run bash "$TEST_DIR/aws-jit-db/setup.sh" <<< ""
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Shared library not found" ]]
}

@test "setup.sh --cleanup exits with error when no state file exists" {
    run bash "$TEST_DIR/aws-jit-db/setup.sh" --cleanup
    [ "$status" -ne 0 ]
    [[ "$output" =~ "No state file found" ]]
}

@test "state file preserves config across resume" {
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    STATE="$TEST_DIR/test-state.json"

    init_state "$STATE" "aws-jit-db" "new-vpc"
    set_config_value "$STATE" "AWS_REGION" "us-east-1"
    set_config_value "$STATE" "VPC_CIDR" "10.50.0.0/16"

    # Simulate resume: reload and verify
    local loaded
    loaded=$(load_state "$STATE")
    [ $? -eq 0 ]
    [ "$(echo "$loaded" | jq -r '.config.AWS_REGION')" = "us-east-1" ]
    [ "$(echo "$loaded" | jq -r '.config.VPC_CIDR')" = "10.50.0.0/16" ]
}

@test "completed steps are skipped on resume" {
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    STATE="$TEST_DIR/test-state.json"

    init_state "$STATE" "aws-jit-db" "new-vpc"
    mark_step_complete "$STATE" "01-sync-ecr" '{"ECR_SYNCED": "true"}'
    mark_step_complete "$STATE" "02-install-workloads-new-vpc" '{"VPC_ID": "vpc-123"}'

    # Verify steps 1 and 2 are complete
    is_step_complete "$STATE" "01-sync-ecr"
    is_step_complete "$STATE" "02-install-workloads-new-vpc"

    # Step 3 should not be complete
    run is_step_complete "$STATE" "03-setup-vpc-peering"
    [ "$status" -ne 0 ]
}

@test "step outputs flow to subsequent steps via state" {
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    STATE="$TEST_DIR/test-state.json"

    init_state "$STATE" "aws-jit-db" "new-vpc"
    mark_step_complete "$STATE" "step-1" '{"VPC_ID": "vpc-abc", "SG_ID": "sg-def"}'

    # Later step should be able to read earlier output
    [ "$(get_step_output "$STATE" "step-1" "VPC_ID")" = "vpc-abc" ]
    [ "$(get_step_output "$STATE" "step-1" "SG_ID")" = "sg-def" ]
}

@test "config.sh loads scope modes correctly" {
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    source "$TEST_DIR/aws-jit-db/config.sh"

    [ "${#SCOPE_MODES[@]}" -eq 3 ]
    [ "${SCOPE_MODES[0]}" = "new-vpc" ]
    [ "${SCOPE_MODES[1]}" = "existing-vpc" ]
    [ "${SCOPE_MODES[2]}" = "same-account" ]
}

@test "config.sh steps for new-vpc are non-empty" {
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    source "$TEST_DIR/aws-jit-db/config.sh"

    steps="${STEPS_FOR_MODE["new-vpc"]}"
    [ -n "$steps" ]
    # Should contain at least sync-ecr
    [[ "$steps" == *"01-sync-ecr"* ]]
}

@test "config.sh defines account context for each step" {
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    source "$TEST_DIR/aws-jit-db/config.sh"

    [ "${STEP_ACCOUNT["01-sync-ecr"]}" = "jit-workload" ]
    [ "${STEP_ACCOUNT["04-accept-peering"]}" = "db-account" ]
    [ "${STEP_ACCOUNT["08-create-permission-set"]}" = "management" ]
}

@test "verify_aws_account succeeds with matching account" {
    # Mock aws returns 123456789012
    unset _CDX_COMMON_LOADED
    source "$TEST_DIR/lib/common.sh"
    verify_aws_account "123456789012"
}
