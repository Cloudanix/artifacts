#!/usr/bin/env bats
# =============================================================================
# Unit Tests: Sensitive Value Masking
# =============================================================================

setup() {
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
}

@test "mask_sensitive masks long string showing last 4 chars" {
    result=$(mask_sensitive "my-secret-api-key-1234")
    # Should end with "1234"
    [[ "$result" == *"1234" ]]
    # Should have asterisks before the last 4
    [[ "$result" == "******************1234" ]]
}

@test "mask_sensitive masks 8-char string" {
    result=$(mask_sensitive "abcd1234")
    [ "$result" = "****1234" ]
}

@test "mask_sensitive shows all asterisks for 4-char string" {
    result=$(mask_sensitive "abcd")
    [ "$result" = "****" ]
}

@test "mask_sensitive shows all asterisks for 3-char string" {
    result=$(mask_sensitive "abc")
    [ "$result" = "***" ]
}

@test "mask_sensitive shows all asterisks for 1-char string" {
    result=$(mask_sensitive "x")
    [ "$result" = "*" ]
}

@test "mask_sensitive handles empty string" {
    result=$(mask_sensitive "")
    [ "$result" = "" ]
}

@test "mask_sensitive masks 5-char string showing last 4" {
    result=$(mask_sensitive "12345")
    [ "$result" = "*2345" ]
}
