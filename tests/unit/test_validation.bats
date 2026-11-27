#!/usr/bin/env bats
# =============================================================================
# Unit Tests: Validation Functions
# =============================================================================

setup() {
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
}

# --- AWS Account ID ---

@test "validate_aws_account_id accepts 12-digit number" {
    validate_aws_account_id "123456789012"
}

@test "validate_aws_account_id rejects 11-digit number" {
    run validate_aws_account_id "12345678901"
    [ "$status" -ne 0 ]
}

@test "validate_aws_account_id rejects 13-digit number" {
    run validate_aws_account_id "1234567890123"
    [ "$status" -ne 0 ]
}

@test "validate_aws_account_id rejects letters" {
    run validate_aws_account_id "12345678901a"
    [ "$status" -ne 0 ]
}

@test "validate_aws_account_id rejects empty string" {
    run validate_aws_account_id ""
    [ "$status" -ne 0 ]
}

# --- Azure Subscription ID ---

@test "validate_azure_subscription_id accepts valid UUID" {
    validate_azure_subscription_id "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}

@test "validate_azure_subscription_id rejects invalid UUID" {
    run validate_azure_subscription_id "not-a-uuid"
    [ "$status" -ne 0 ]
}

@test "validate_azure_subscription_id rejects uppercase" {
    run validate_azure_subscription_id "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
    [ "$status" -ne 0 ]
}

# --- CIDR ---

@test "validate_cidr accepts valid CIDR" {
    validate_cidr "10.0.0.0/16"
}

@test "validate_cidr accepts /24" {
    validate_cidr "192.168.1.0/24"
}

@test "validate_cidr rejects missing prefix" {
    run validate_cidr "10.0.0.0"
    [ "$status" -ne 0 ]
}

@test "validate_cidr rejects letters" {
    run validate_cidr "abc.def.ghi.jkl/16"
    [ "$status" -ne 0 ]
}

# --- ARN ---

@test "validate_arn accepts valid AWS ARN" {
    validate_arn "arn:aws:iam::123456789012:role/MyRole"
}

@test "validate_arn accepts ARN with region" {
    validate_arn "arn:aws:ecs:us-east-1:123456789012:cluster/my-cluster"
}

@test "validate_arn rejects non-ARN string" {
    run validate_arn "not-an-arn"
    [ "$status" -ne 0 ]
}

# --- Region ---

@test "validate_region accepts us-east-1" {
    validate_region "us-east-1"
}

@test "validate_region accepts ap-south-1" {
    validate_region "ap-south-1"
}

@test "validate_region rejects unknown region" {
    run validate_region "xx-fake-99"
    [ "$status" -ne 0 ]
}

# --- Alphanumeric Dash ---

@test "validate_alphanumeric_dash accepts valid string" {
    validate_alphanumeric_dash "cdx-jit-db-cluster"
}

@test "validate_alphanumeric_dash rejects underscores" {
    run validate_alphanumeric_dash "cdx_jit_db"
    [ "$status" -ne 0 ]
}

@test "validate_alphanumeric_dash rejects spaces" {
    run validate_alphanumeric_dash "cdx jit db"
    [ "$status" -ne 0 ]
}

# --- Semver or Latest ---

@test "validate_semver_or_latest accepts latest" {
    validate_semver_or_latest "latest"
}

@test "validate_semver_or_latest accepts 1.2.3" {
    validate_semver_or_latest "1.2.3"
}

@test "validate_semver_or_latest accepts 0.1.0-beta" {
    validate_semver_or_latest "0.1.0-beta"
}

@test "validate_semver_or_latest rejects incomplete version" {
    run validate_semver_or_latest "1.2"
    [ "$status" -ne 0 ]
}

# --- Boolean ---

@test "validate_boolean accepts true" {
    validate_boolean "true"
}

@test "validate_boolean accepts false" {
    validate_boolean "false"
}

@test "validate_boolean rejects yes" {
    run validate_boolean "yes"
    [ "$status" -ne 0 ]
}

# --- Nonempty ---

@test "validate_nonempty accepts non-empty string" {
    validate_nonempty "hello"
}

@test "validate_nonempty rejects empty string" {
    run validate_nonempty ""
    [ "$status" -ne 0 ]
}

# --- Dispatcher ---

@test "validate dispatches aws_account_id correctly" {
    validate "123456789012" "aws_account_id"
}

@test "validate dispatches cidr correctly" {
    validate "10.0.0.0/16" "cidr"
}

@test "validate dispatches unknown rule as nonempty" {
    validate "anything" "unknown_rule"
}
