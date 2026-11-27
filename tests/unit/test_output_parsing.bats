#!/usr/bin/env bats
# =============================================================================
# Unit Tests: OUTPUT Protocol Parsing
# =============================================================================

setup() {
    unset _CDX_COMMON_LOADED
    source "$BATS_TEST_DIRNAME/../../lib/common.sh"
}

@test "parse_step_output extracts single valid OUTPUT line" {
    input="OUTPUT:VPC_ID=vpc-12345"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq -r '.VPC_ID')" = "vpc-12345" ]
}

@test "parse_step_output extracts multiple valid OUTPUT lines" {
    input="OUTPUT:VPC_ID=vpc-12345
OUTPUT:SUBNET_ID=subnet-abc"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq -r '.VPC_ID')" = "vpc-12345" ]
    [ "$(echo "$result" | jq -r '.SUBNET_ID')" = "subnet-abc" ]
}

@test "parse_step_output ignores non-OUTPUT lines" {
    input="some log line
[INFO] doing stuff
OUTPUT:KEY=value
another log"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq 'keys | length')" = "1" ]
    [ "$(echo "$result" | jq -r '.KEY')" = "value" ]
}

@test "parse_step_output warns on malformed OUTPUT line (no equals)" {
    input="OUTPUT:INVALID"
    result=$(parse_step_output "$input" 2>&1)
    [[ "$result" =~ "Malformed OUTPUT line" ]]
}

@test "parse_step_output rejects key starting with lowercase" {
    input="OUTPUT:lowercase=value"
    result=$(parse_step_output "$input" 2>&1)
    [[ "$result" =~ "Malformed OUTPUT line" ]]
}

@test "parse_step_output rejects key starting with number" {
    input="OUTPUT:1INVALID=value"
    result=$(parse_step_output "$input" 2>&1)
    [[ "$result" =~ "Malformed OUTPUT line" ]]
}

@test "parse_step_output accepts key with underscores" {
    input="OUTPUT:MY_VPC_ID=vpc-123"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq -r '.MY_VPC_ID')" = "vpc-123" ]
}

@test "parse_step_output returns empty object for no OUTPUT lines" {
    input="just regular logs
nothing to see here"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq 'keys | length')" = "0" ]
}

@test "parse_step_output handles empty input" {
    result=$(parse_step_output "")
    [ "$(echo "$result" | jq 'keys | length')" = "0" ]
}

@test "parse_step_output accepts value with special chars" {
    input="OUTPUT:ARN=arn:aws:iam::123456789012:role/my-role"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq -r '.ARN')" = "arn:aws:iam::123456789012:role/my-role" ]
}

@test "parse_step_output accepts value with equals signs" {
    input="OUTPUT:ENCODED=base64==data"
    result=$(parse_step_output "$input")
    [ "$(echo "$result" | jq -r '.ENCODED')" = "base64==data" ]
}
