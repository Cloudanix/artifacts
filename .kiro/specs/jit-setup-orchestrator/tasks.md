# Implementation Plan: JIT Setup Orchestrator

## Overview

This plan implements a bash-based orchestration system that unifies five JIT setup workflows behind a consistent, resumable, idempotent execution framework. Implementation proceeds bottom-up: shared library first, then configuration schemas, step scripts, orchestrators, cleanup scripts, and finally tests. The property-based tests use fast-check (Node.js) and unit tests use bats-core.

## Tasks

- [x] 1. Create shared library (lib/common.sh)
  - [x] 1.1 Implement logging functions
    - Create `lib/common.sh` with shebang and color detection logic (check TERM and TTY)
    - Implement `log()`, `ok()`, `info()`, `warn()`, `error()`, `step()` functions
    - Format: `[HH:MM:SS] [SEVERITY] message` with ANSI colors when supported
    - Export all functions
    - _Requirements: 3.1, 6.2, 6.3, 6.4_

  - [x] 1.2 Implement prompt functions
    - Implement `prompt_with_default()` — displays prompt with default in brackets, returns input or default
    - Implement `prompt_yes_no()` — returns 0 for yes, 1 for no
    - Implement `prompt_selection()` — numbered menu with retry up to 3 times on invalid input
    - _Requirements: 3.2, 6.2, 1.6_

  - [x] 1.3 Implement state management functions
    - Implement `save_state()` — atomic write via temp file + mv
    - Implement `load_state()` — parse JSON, return 0 if valid, 1 if corrupt/missing
    - Implement `mark_step_complete()` — mark step with timestamp and outputs
    - Implement `is_step_complete()` — check step completion status
    - Implement `get_step_output()` — retrieve output value for a completed step
    - Implement `set_config_value()` and `get_config_value()` — config storage/retrieval
    - _Requirements: 4.2, 4.6, 4.8, 6.2_

  - [x] 1.4 Implement account verification functions
    - Implement `verify_aws_account()` — runs `aws sts get-caller-identity`, compares account ID
    - Implement `verify_azure_subscription()` — runs `az account show`, compares subscription ID
    - _Requirements: 5.3, 5.4, 6.2_

  - [x] 1.5 Implement validation functions
    - Implement validators: `validate_aws_account_id`, `validate_azure_subscription_id`, `validate_cidr`, `validate_arn`, `validate_region`, `validate_alphanumeric_dash`, `validate_semver_or_latest`, `validate_boolean`, `validate_nonempty`
    - Each validator returns 0 on match, 1 on mismatch
    - _Requirements: 7.2, 6.2_

  - [x] 1.6 Implement error handling and progress display
    - Implement `handle_error()` — ERR trap handler that logs line number + exit code
    - Implement `show_progress()` — displays `[Step N/M] (XX%) step_name`
    - Implement `mask_sensitive()` — masks all but last 4 chars with asterisks
    - _Requirements: 3.3, 3.5, 7.3_

  - [x] 1.7 Implement OUTPUT protocol parsing
    - Implement `parse_step_output()` — extracts valid `OUTPUT:<KEY>=<VALUE>` lines from stdout
    - KEY: `[A-Z][A-Z0-9_]{0,63}`, VALUE: max 256 chars, no newlines
    - Log warning for malformed lines matching `OUTPUT:` prefix but invalid format
    - _Requirements: 8.1, 8.2, 8.5_

- [x] 2. Create configuration schemas (config.sh per setup type)
  - [x] 2.1 Create aws-jit-db/config.sh
    - Define SCOPE_MODES array with labels
    - Define STEPS_FOR_MODE associative array
    - Define STEP_ACCOUNT and STEP_LABELS maps
    - Define CONFIG_FIELDS with validation rules, defaults, scope modes
    - _Requirements: 1.1, 1.2, 7.6_

  - [x] 2.2 Create aws-jit-vm/config.sh
    - Define scope modes (new-vpc, existing-vpc)
    - Define step sequences, account mappings, labels
    - Define configuration fields for VM setup
    - _Requirements: 1.1, 1.2, 7.6_

  - [x] 2.3 Create aws-jit-eks/config.sh
    - Define scope modes (new-vpc, existing-vpc)
    - Define step sequences, account mappings, labels
    - Define configuration fields for EKS setup
    - _Requirements: 1.1, 1.2, 7.6_

  - [x] 2.4 Create azure-jit-db/config.sh
    - Define scope modes for Azure DB setup
    - Define step sequences, account mappings, labels
    - Define configuration fields with Azure-specific validation (subscription IDs)
    - _Requirements: 1.1, 1.2, 7.6_

  - [x] 2.5 Create azure-jit-k8s/config.sh
    - Define scope modes for Azure K8s setup
    - Define step sequences, account mappings, labels
    - Define configuration fields with Azure-specific validation
    - _Requirements: 1.1, 1.2, 7.6_

- [x] 3. Implement orchestrator (setup.sh) template and first instance
  - [x] 3.1 Implement the orchestrator script for aws-jit-db/setup.sh
    - Source lib/common.sh and config.sh
    - Implement `--cleanup` flag handling
    - Implement scope mode selection menu
    - Implement state file load/create with resume prompt
    - Implement configuration collection loop (validate, store, confirm, re-edit)
    - Implement step execution loop: account verification → execute step → parse outputs → update state
    - Implement account switch banner display (colored, bordered)
    - Implement completion summary display
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 1.6, 1.7, 4.1, 4.3, 4.4, 4.5, 4.7, 5.1, 5.2, 5.3, 5.4, 5.5, 7.1, 7.2, 7.3, 7.4, 7.7, 8.2, 8.3, 8.4_

  - [x] 3.2 Create orchestrators for remaining setup types
    - Create aws-jit-vm/setup.sh, aws-jit-eks/setup.sh, azure-jit-db/setup.sh, azure-jit-k8s/setup.sh
    - Each sources lib/common.sh and its own config.sh
    - Reuse the same orchestration logic pattern from aws-jit-db/setup.sh
    - _Requirements: 1.3, 6.1_

- [ ] 4. Checkpoint - Core framework validation
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. Implement step scripts for aws-jit-db
  - [x] 5.1 Implement aws-jit-db/steps/01-sync-ecr.sh
    - Source lib/common.sh, validate required env vars (AWS_REGION, JIT_ACCOUNT_ID, IMAGE_TAG, PROJECT_NAME)
    - Check-before-create: verify ECR repo exists before creating
    - Emit `OUTPUT:ECR_REPO_URI=<value>`
    - _Requirements: 2.1, 2.2, 2.5, 2.6, 2.7, 8.1_

  - [x] 5.2 Implement aws-jit-db/steps/02-install-workloads.sh
    - Install ECS cluster, VPC, subnets, security groups, task definitions
    - Check-before-create for each resource
    - Emit OUTPUT for VPC_ID, PRIVATE_SUBNET_1_ID, PRIVATE_SUBNET_2_ID, CLUSTER_NAME, ECS_ROLE_ARN
    - _Requirements: 2.1, 2.2, 2.4, 2.5, 2.6, 2.7, 8.1_

  - [x] 5.3 Implement aws-jit-db/steps/03-setup-vpc-peering.sh
    - Create VPC peering connection request
    - Emit OUTPUT:PEERING_CONNECTION_ID
    - _Requirements: 2.1, 2.2, 2.5, 2.6, 2.7, 8.1_

  - [x] 5.4 Implement aws-jit-db/steps/04-accept-peering.sh
    - Accept VPC peering connection in DB account
    - Update route tables
    - Emit OUTPUT:PEERING_STATUS
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6, 2.7, 8.1_

  - [x] 5.5 Implement aws-jit-db/steps/05-update-assume-role.sh
    - Update IAM assume role policy
    - _Requirements: 2.1, 2.3, 2.5, 2.6, 2.7, 8.1_

  - [x] 5.6 Implement aws-jit-db/steps/06-create-permission-set.sh
    - Create SSO permission set in management account
    - Emit OUTPUT:PERMISSION_SET_ARN
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6, 2.7, 8.1_

- [x] 6. Implement step scripts for aws-jit-vm
  - [x] 6.1 Implement aws-jit-vm/steps/01-create-permission-set.sh
    - Create SSO permission set in management account
    - Emit OUTPUT:PERMISSION_SET_ARN
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6, 2.7, 8.1_

  - [x] 6.2 Implement aws-jit-vm/steps/02-sync-ecr.sh through 06-store-ssh-key.sh
    - Implement remaining 5 step scripts for VM setup type
    - Each follows the idempotent pattern: check-before-create, emit OUTPUT lines
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 8.1_

- [x] 7. Implement step scripts for aws-jit-eks
  - [x] 7.1 Implement aws-jit-eks/steps/01-attach-eks-policies.sh through 05-create-permission-sets.sh
    - Implement all 5 step scripts for EKS setup type
    - Each follows the idempotent pattern: check-before-create, emit OUTPUT lines
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 8.1_

- [ ] 8. Implement step scripts for azure-jit-db
  - [ ] 8.1 Implement azure-jit-db/steps/01-sync-acr.sh through 06-create-sp-and-binding.sh
    - Implement all 6 step scripts for Azure DB setup type
    - Each follows the idempotent pattern with Azure CLI
    - Use `az` commands for resource existence checks
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 8.1_

- [ ] 9. Implement step scripts for azure-jit-k8s
  - [ ] 9.1 Implement azure-jit-k8s/steps/01-create-custom-roles.sh through 04-extend-role-scopes.sh
    - Implement all 4 step scripts for Azure K8s setup type
    - Each follows the idempotent pattern with Azure CLI
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 8.1_

- [ ] 10. Implement cleanup scripts
  - [ ] 10.1 Implement aws-jit-db/cleanup/cleanup.sh
    - Read state file to determine created resources
    - Delete resources in reverse order of creation
    - Wrap each deletion in `|| true` to continue on failure
    - Display summary of successes and failures
    - _Requirements: 9.1, 9.2, 9.3, 9.4_

  - [ ] 10.2 Implement cleanup scripts for remaining setup types
    - Create aws-jit-vm/cleanup/cleanup.sh, aws-jit-eks/cleanup/cleanup.sh, azure-jit-db/cleanup/cleanup.sh, azure-jit-k8s/cleanup/cleanup.sh
    - Each follows the reverse-order pattern with failure continuation
    - _Requirements: 9.1, 9.2, 9.3, 9.4_

- [ ] 11. Checkpoint - Full implementation validation
  - Ensure all tests pass, ask the user if questions arise.

- [x] 12. Set up test infrastructure and write unit tests
  - [x] 12.1 Set up bats-core test framework
    - Create `tests/` directory structure with `tests/unit/` and `tests/integration/`
    - Add bats-core as a git submodule or document install instructions
    - Create test helper file that sources lib/common.sh with mocked dependencies
    - _Requirements: 6.2_

  - [x] 12.2 Write unit tests for logging functions
    - Test output format matches `[HH:MM:SS] [SEVERITY] message` for all severity levels
    - Test color output when TTY is available
    - Test plain text output when TERM=dumb or non-TTY
    - _Requirements: 3.1, 6.3_

  - [x] 12.3 Write unit tests for validation functions
    - Test each rule with known valid inputs (pass cases)
    - Test each rule with known invalid inputs (reject cases)
    - Test edge cases: empty strings, max length, special characters
    - _Requirements: 7.2_

  - [x] 12.4 Write unit tests for state management functions
    - Test save_state atomic write (temp file + mv)
    - Test load_state with valid JSON, invalid JSON, missing file
    - Test mark_step_complete, is_step_complete, get_step_output
    - Test set_config_value, get_config_value round-trip
    - _Requirements: 4.2, 4.6, 4.8_

  - [x] 12.5 Write unit tests for OUTPUT protocol parsing
    - Test extraction of valid OUTPUT lines from mixed stdout
    - Test rejection of malformed OUTPUT lines
    - Test warning logging for invalid format
    - _Requirements: 8.1, 8.2, 8.5_

  - [x] 12.6 Write unit tests for prompt functions
    - Test prompt_with_default returns default on empty input (mocked stdin)
    - Test prompt_selection retry logic on invalid input
    - Test prompt_yes_no returns correct exit codes
    - _Requirements: 3.2, 1.6_

  - [x] 12.7 Write unit tests for account verification
    - Test verify_aws_account with mocked aws CLI (match and mismatch cases)
    - Test verify_azure_subscription with mocked az CLI
    - _Requirements: 5.3, 5.4_

- [ ] 13. Set up property-based test infrastructure and write property tests
  - [ ] 13.1 Set up fast-check test harness
    - Create `tests/property/` directory
    - Initialize Node.js project with package.json (fast-check, vitest dependencies)
    - Create test harness that shells out to bash functions under test
    - Create helper utilities for generating random inputs and invoking bash
    - _Requirements: 6.2_

  - [ ]* 13.2 Write property test for state file round-trip integrity
    - **Property 1: State file round-trip integrity**
    - Generate random config maps, step IDs, timestamps, output maps
    - Serialize via save_state, deserialize via load_state
    - Assert all values are identical after round-trip
    - **Validates: Requirements 4.2, 4.6, 8.3**

  - [ ]* 13.3 Write property test for OUTPUT protocol parsing correctness
    - **Property 2: OUTPUT protocol parsing correctness**
    - Generate random mix of log lines, valid OUTPUT lines, and malformed OUTPUT lines
    - Assert parser extracts exactly the valid pairs and ignores all others
    - **Validates: Requirements 8.1, 8.2, 8.5**

  - [ ]* 13.4 Write property test for configuration validation correctness
    - **Property 3: Configuration validation correctness**
    - Generate random strings × each validation rule
    - Assert validation returns success iff input matches the rule's regex
    - **Validates: Requirements 7.2**

  - [ ]* 13.5 Write property test for step sequencing invariants
    - **Property 4: Step sequencing invariants**
    - Generate random (setup_type, scope_mode) pairs from config schemas
    - Assert returned step list is non-empty, no duplicates, valid subsequence
    - **Validates: Requirements 1.2**

  - [ ]* 13.6 Write property test for resume skips exactly completed steps
    - **Property 5: Resume skips exactly completed steps**
    - Generate random state with K/M steps complete
    - Assert pending list has exactly M-K items starting at step K+1
    - **Validates: Requirements 4.3, 4.4**

  - [ ]* 13.7 Write property test for logging format consistency
    - **Property 6: Logging format consistency**
    - Generate random message strings × each logging function
    - Assert output matches `\[HH:MM:SS\] \[SEVERITY\] .*` pattern
    - **Validates: Requirements 3.1, 3.5**

  - [ ]* 13.8 Write property test for sensitive value masking
    - **Property 7: Sensitive value masking**
    - Generate random strings of length 0-100
    - Assert first max(0, L-4) chars are asterisks and last min(4, L) chars visible
    - **Validates: Requirements 7.3**

  - [ ]* 13.9 Write property test for cleanup reverse ordering and continuation
    - **Property 8: Cleanup reverse ordering and continuation**
    - Generate random completed step lists
    - Assert cleanup invoked in reverse order; failures don't halt remaining
    - **Validates: Requirements 9.2, 9.3**

- [ ] 14. Write integration tests
  - [ ]* 14.1 Write integration tests for full orchestrator flow
    - Create bats tests with mock aws/az CLI functions
    - Test fresh setup: all steps execute in order, state file created
    - Test resume: state with 2/5 complete → only remaining steps execute
    - Test account mismatch: banner re-prompts shown
    - Test idempotent rerun: all resources "exist" → no creation calls
    - _Requirements: 1.2, 1.4, 1.5, 4.3, 4.4, 5.3, 5.4_

  - [ ]* 14.2 Write integration tests for error scenarios
    - Test validation rejection: invalid inputs rejected, valid accepted
    - Test corrupt state file: error message + prompt to start fresh
    - Test missing library: error + exit with path
    - Test cleanup with partial failures: remaining steps still execute
    - _Requirements: 1.6, 4.7, 6.5, 9.3_

- [ ] 15. Final checkpoint - All tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- The orchestrator logic in task 3.1 is the core template; tasks 3.2 reuses that pattern
- Step scripts (tasks 5-9) follow the same idempotent pattern but with different cloud commands
- All bash scripts require bash 4+ and jq; property tests require Node.js 18+

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "12.1", "13.1"] },
    { "id": 1, "tasks": ["1.2", "1.3", "1.4", "1.5", "1.6", "1.7"] },
    { "id": 2, "tasks": ["2.1", "2.2", "2.3", "2.4", "2.5", "12.2", "12.3", "12.5", "12.6", "12.7"] },
    { "id": 3, "tasks": ["3.1", "12.4", "13.2", "13.3", "13.4", "13.7", "13.8"] },
    { "id": 4, "tasks": ["3.2", "13.5", "13.6"] },
    { "id": 5, "tasks": ["5.1", "5.2", "5.3", "5.4", "5.5", "5.6", "6.1", "6.2", "7.1", "8.1", "9.1"] },
    { "id": 6, "tasks": ["10.1", "10.2"] },
    { "id": 7, "tasks": ["14.1", "14.2", "13.9"] }
  ]
}
```
