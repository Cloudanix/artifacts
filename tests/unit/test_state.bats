#!/usr/bin/env bats
# =============================================================================
# Unit Tests: State Management Functions
# =============================================================================

setup() {
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
    export TEST_STATE="/tmp/bats-test-state-$$.json"
    rm -f "$TEST_STATE" "${TEST_STATE}.tmp"
}

teardown() {
    rm -f "$TEST_STATE" "${TEST_STATE}.tmp"
}

# --- init_state ---

@test "init_state creates valid JSON with required fields" {
    init_state "$TEST_STATE" "aws-jit-db" "new-vpc"
    [ -f "$TEST_STATE" ]
    run jq -e '.version' "$TEST_STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.setup_type' "$TEST_STATE")" = "aws-jit-db" ]
    [ "$(jq -r '.scope_mode' "$TEST_STATE")" = "new-vpc" ]
    [ "$(jq -r '.config' "$TEST_STATE")" = "{}" ]
    [ "$(jq -r '.steps' "$TEST_STATE")" = "{}" ]
}

@test "init_state sets started_at as ISO 8601 UTC" {
    init_state "$TEST_STATE" "aws-jit-vm" "existing-vpc"
    started=$(jq -r '.started_at' "$TEST_STATE")
    [[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# --- save_state / load_state ---

@test "save_state writes atomically (no .tmp file remains)" {
    init_state "$TEST_STATE" "test" "mode"
    [ ! -f "${TEST_STATE}.tmp" ]
}

@test "load_state returns 0 for valid state file" {
    init_state "$TEST_STATE" "aws-jit-db" "new-vpc"
    run load_state "$TEST_STATE"
    [ "$status" -eq 0 ]
}

@test "load_state returns 1 for missing file" {
    run load_state "/tmp/nonexistent-state-$$.json"
    [ "$status" -eq 1 ]
}

@test "load_state returns 1 for invalid JSON" {
    echo "not json" > "$TEST_STATE"
    run load_state "$TEST_STATE"
    [ "$status" -eq 1 ]
}

@test "load_state returns 1 for JSON missing required fields" {
    echo '{"foo": "bar"}' > "$TEST_STATE"
    run load_state "$TEST_STATE"
    [ "$status" -eq 1 ]
}

# --- set_config_value / get_config_value ---

@test "set_config_value stores value retrievable by get_config_value" {
    init_state "$TEST_STATE" "test" "mode"
    set_config_value "$TEST_STATE" "AWS_REGION" "us-east-1"
    result=$(get_config_value "$TEST_STATE" "AWS_REGION")
    [ "$result" = "us-east-1" ]
}

@test "get_config_value returns empty for missing key" {
    init_state "$TEST_STATE" "test" "mode"
    result=$(get_config_value "$TEST_STATE" "NONEXISTENT")
    [ "$result" = "" ]
}

@test "set_config_value overwrites existing value" {
    init_state "$TEST_STATE" "test" "mode"
    set_config_value "$TEST_STATE" "REGION" "us-east-1"
    set_config_value "$TEST_STATE" "REGION" "eu-west-1"
    result=$(get_config_value "$TEST_STATE" "REGION")
    [ "$result" = "eu-west-1" ]
}

# --- mark_step_complete / is_step_complete ---

@test "mark_step_complete marks step as complete" {
    init_state "$TEST_STATE" "test" "mode"
    mark_step_complete "$TEST_STATE" "01-sync-ecr" '{"ECR_SYNCED": "true"}'
    is_step_complete "$TEST_STATE" "01-sync-ecr"
}

@test "is_step_complete returns 1 for incomplete step" {
    init_state "$TEST_STATE" "test" "mode"
    run is_step_complete "$TEST_STATE" "01-sync-ecr"
    [ "$status" -eq 1 ]
}

@test "mark_step_complete records ISO 8601 timestamp" {
    init_state "$TEST_STATE" "test" "mode"
    mark_step_complete "$TEST_STATE" "step-1" '{}'
    ts=$(jq -r '.steps["step-1"].completed_at' "$TEST_STATE")
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "mark_step_complete stores outputs" {
    init_state "$TEST_STATE" "test" "mode"
    mark_step_complete "$TEST_STATE" "step-1" '{"VPC_ID": "vpc-123", "SG_ID": "sg-456"}'
    [ "$(jq -r '.steps["step-1"].outputs.VPC_ID' "$TEST_STATE")" = "vpc-123" ]
    [ "$(jq -r '.steps["step-1"].outputs.SG_ID' "$TEST_STATE")" = "sg-456" ]
}

# --- get_step_output ---

@test "get_step_output retrieves stored output value" {
    init_state "$TEST_STATE" "test" "mode"
    mark_step_complete "$TEST_STATE" "step-1" '{"VPC_ID": "vpc-abc"}'
    result=$(get_step_output "$TEST_STATE" "step-1" "VPC_ID")
    [ "$result" = "vpc-abc" ]
}

@test "get_step_output returns empty for missing key" {
    init_state "$TEST_STATE" "test" "mode"
    mark_step_complete "$TEST_STATE" "step-1" '{"VPC_ID": "vpc-abc"}'
    result=$(get_step_output "$TEST_STATE" "step-1" "NONEXISTENT")
    [ "$result" = "" ]
}

# --- Multiple steps ---

@test "multiple steps can be marked complete independently" {
    init_state "$TEST_STATE" "test" "mode"
    mark_step_complete "$TEST_STATE" "step-1" '{"A": "1"}'
    mark_step_complete "$TEST_STATE" "step-2" '{"B": "2"}'
    mark_step_complete "$TEST_STATE" "step-3" '{"C": "3"}'

    is_step_complete "$TEST_STATE" "step-1"
    is_step_complete "$TEST_STATE" "step-2"
    is_step_complete "$TEST_STATE" "step-3"

    [ "$(get_step_output "$TEST_STATE" "step-1" "A")" = "1" ]
    [ "$(get_step_output "$TEST_STATE" "step-2" "B")" = "2" ]
    [ "$(get_step_output "$TEST_STATE" "step-3" "C")" = "3" ]
}
