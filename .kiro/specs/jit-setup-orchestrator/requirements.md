# Requirements Document

## Introduction

The JIT Setup Orchestrator is a master orchestration system that standardizes and simplifies the customer experience across five JIT (Just-In-Time) setup types: AWS JIT Database, AWS JIT VM, AWS JIT EKS, Azure JIT DB, and Azure JIT K8s. Each setup currently involves multiple scripts run in sequence across multiple cloud accounts with manual account switching, inconsistent UX patterns, no progress tracking, and no resumability. The orchestrator provides a unified entry point per setup type that guides customers through the full setup flow with consistent logging, idempotent operations, state tracking, and clear multi-account guidance.

## Glossary

- **Orchestrator**: The master shell script (`setup.sh`) per setup type that drives the full setup workflow by invoking individual step scripts in sequence
- **Step_Script**: An individual shell script that performs a single unit of work (e.g., sync ECR images, create VPC, accept peering) within the overall setup flow
- **State_File**: A JSON file persisted to disk that records which steps have completed, their outputs, and user-provided configuration values
- **Shared_Library**: A common shell library (`lib/common.sh`) containing reusable functions for logging, prompting, error handling, and state management
- **Setup_Type**: One of the five supported JIT products: aws-jit-db, aws-jit-vm, aws-jit-eks, azure-jit-db, azure-jit-k8s
- **Account_Context**: The cloud account (AWS account or Azure subscription) in which a step executes
- **Scope_Mode**: The deployment topology variant — VPC-scoped (new VPC with peering), central-scoped (existing VPC), or same-account (existing VPC in same account as DB)
- **Idempotent_Operation**: An operation that checks whether a resource already exists before attempting creation, making repeated execution safe
- **Progress_Indicator**: A visual display showing the current step number, total steps, and completion percentage

## Requirements

### Requirement 1: Master Orchestrator Entry Point

**User Story:** As a customer, I want a single entry point script per setup type, so that I do not need to manually determine and execute each step script in the correct order.

#### Acceptance Criteria

1. WHEN a customer executes the orchestrator script for a Setup_Type, THE Orchestrator SHALL present a numbered menu of available Scope_Mode options for that Setup_Type and wait for the customer to select one by entering the corresponding number
2. WHEN the customer selects a Scope_Mode, THE Orchestrator SHALL determine the ordered list of Step_Scripts required for that Setup_Type and Scope_Mode combination and execute them sequentially in the defined order
3. THE Orchestrator SHALL support the following Setup_Types: aws-jit-db, aws-jit-vm, aws-jit-eks, azure-jit-db, azure-jit-k8s
4. WHEN a Step_Script completes successfully, THE Orchestrator SHALL advance to the next Step_Script automatically without requiring additional user intervention beyond what the next step's Account_Context switch requires
5. IF a Step_Script exits with a non-zero exit code, THEN THE Orchestrator SHALL halt sequential execution, log the name of the failed Step_Script and its exit code, and exit without executing subsequent steps
6. IF the customer enters a selection that does not correspond to any listed Scope_Mode option, THEN THE Orchestrator SHALL display an error message indicating the valid range of options and re-present the menu up to 3 consecutive invalid attempts before exiting
7. WHEN all Step_Scripts in the sequence complete successfully, THE Orchestrator SHALL display a completion summary listing each Step_Script name and its completion status

### Requirement 2: Idempotent Step Scripts

**User Story:** As a customer, I want every step script to be safe to re-run, so that I can recover from partial failures without creating duplicate resources.

#### Acceptance Criteria

1. WHEN a Step_Script creates a cloud resource, THE Step_Script SHALL query for an existing resource matching the same identifying attributes (name tag, CIDR, or unique name) before attempting creation, and SHALL skip creation if a matching resource is found
2. WHEN a resource already exists and is reused, THE Step_Script SHALL print a message to stdout indicating the resource identifier and that it was found existing
3. WHEN a Step_Script attaches a policy or role assignment, THE Step_Script SHALL treat the "already attached" response from the cloud provider as a success and continue execution without error
4. IF a Step_Script fails partway through, THEN THE Step_Script SHALL exit with a non-zero exit code and SHALL leave successfully-created resources intact so that subsequent re-execution resumes from the point of failure
5. THE Step_Script SHALL accept all required input values as environment variables or command-line arguments, and SHALL NOT prompt the user interactively during execution
6. IF a required environment variable or command-line argument is not provided, THEN THE Step_Script SHALL exit with a non-zero exit code within 5 seconds of invocation and SHALL print a message to stderr identifying the missing parameter by name
7. WHEN a Step_Script completes all operations successfully, THE Step_Script SHALL exit with exit code 0

### Requirement 3: Consistent User Experience

**User Story:** As a customer, I want a consistent look and feel across all setup scripts, so that I can easily follow progress regardless of which setup type I am running.

#### Acceptance Criteria

1. THE Shared_Library SHALL provide standardized logging functions that prefix messages with a timestamp in HH:MM:SS format and a severity indicator (one of: info, success, warning, error)
2. THE Shared_Library SHALL provide a standardized prompt function that displays the prompt text, a default value in square brackets, and returns the user-provided input or the default value when the user submits empty input
3. WHEN a Step_Script begins execution, THE Orchestrator SHALL display a Progress_Indicator in the format "[Step N/M]" where N is the current step number and M is the total number of steps in the setup flow
4. WHEN a Step_Script completes, THE Orchestrator SHALL display a summary listing each resource affected during the step with its resource type, identifier, and status (created or reused)
5. THE Shared_Library SHALL provide a standardized error handler that captures the failing line number and the non-zero exit code, logs an error message indicating the line number and exit code, and terminates the script with the captured non-zero exit code
6. IF a Step_Script completes without creating or modifying any resources, THEN THE Orchestrator SHALL display a summary indicating that no changes were made

### Requirement 4: Progress and State Tracking

**User Story:** As a customer, I want interrupted setups to be resumable, so that I do not need to re-enter configuration values or re-run already-completed steps.

#### Acceptance Criteria

1. WHEN the Orchestrator starts a setup, THE Orchestrator SHALL create or load an existing State_File named `.state.json` in the root of the setup directory for the active Setup_Type
2. WHEN a Step_Script completes successfully, THE Orchestrator SHALL record the step identifier, an ISO 8601 UTC completion timestamp, and any output values in the State_File
3. WHEN the Orchestrator is restarted and a State_File exists, THE Orchestrator SHALL prompt the customer to resume from the last incomplete step or start fresh
4. WHEN the customer chooses to resume, THE Orchestrator SHALL skip all steps already marked complete in the State_File and use previously captured configuration values
5. WHEN the customer chooses to start fresh, THE Orchestrator SHALL delete the existing State_File and begin the setup from the first step, collecting all configuration values anew
6. THE Orchestrator SHALL record all user-provided configuration values in the State_File so they do not need to be re-entered on resume
7. IF the State_File exists but cannot be parsed as valid JSON, THEN THE Orchestrator SHALL display an error message indicating the file is corrupted, prompt the customer to start fresh or abort, and SHALL NOT proceed with a resume until a valid State_File is available
8. WHEN the Orchestrator writes to the State_File, THE Orchestrator SHALL write to a temporary file in the same directory and rename it to the State_File path upon successful write, so that an interruption during write does not corrupt the State_File

### Requirement 5: Multi-Account Guidance

**User Story:** As a customer, I want clear instructions on when to switch cloud accounts and what credentials are needed, so that I do not run scripts in the wrong account context.

#### Acceptance Criteria

1. WHEN the next Step_Script requires a different Account_Context than the current context, THE Orchestrator SHALL display a visually separated banner (using distinct color formatting and horizontal rule borders) indicating the required account switch, including the target account name and identifier
2. WHEN an Account_Context transition occurs, THE Orchestrator SHALL display the expected account identifier (AWS Account ID or Azure Subscription ID), the account label as defined in the configuration, and the name of the upcoming Step_Script that requires the new context
3. WHEN the customer confirms the account switch, THE Orchestrator SHALL invoke the appropriate credential verification function (verify_aws_account or verify_azure_subscription from the Shared_Library) to confirm the active credentials match the expected Account_Context before proceeding
4. IF the active credentials do not match the expected Account_Context, THEN THE Orchestrator SHALL display the expected account identifier, the actual account identifier returned by the credential check, and prompt the customer to correct credentials and confirm again
5. WHEN the Orchestrator begins execution of the first Step_Script in the flow, THE Orchestrator SHALL verify the active credentials match the Account_Context required by that first step before executing it

### Requirement 6: Shared Library

**User Story:** As a developer, I want common functions extracted into a shared library, so that all setup scripts use identical implementations and updates propagate to all setup types.

#### Acceptance Criteria

1. THE Shared_Library SHALL be sourced by all Step_Scripts and the Orchestrator at the beginning of execution, before any function calls or variable references that depend on library functions
2. THE Shared_Library SHALL provide functions for: logging (log, ok, info, warn, error, step), prompting (prompt_with_default, prompt_yes_no, prompt_selection), state management (save_state, load_state, mark_step_complete, is_step_complete), progress display (show_progress), account verification (verify_aws_account, verify_azure_subscription), and error handling (handle_error trap)
3. IF the terminal does not support color output (determined by checking the TERM environment variable and whether stdout is a TTY), THEN THE Shared_Library SHALL omit ANSI escape codes and output plain text with text-based severity prefixes (e.g., [OK], [INFO], [WARN], [ERROR])
4. THE Shared_Library SHALL export all functions so they are available to step scripts sourced after the library
5. IF the Shared_Library file does not exist at the expected relative path when a Step_Script or Orchestrator attempts to source it, THEN the script SHALL print an error message to stderr identifying the missing file path and exit with a non-zero exit code

### Requirement 7: Configuration Collection Up Front

**User Story:** As a customer, I want to provide all configuration values at the beginning of the setup, so that I am not interrupted mid-flow to look up account IDs or CIDR ranges.

#### Acceptance Criteria

1. WHEN a setup begins and no State_File exists, THE Orchestrator SHALL collect all required configuration values for the entire flow before executing the first Step_Script
2. WHEN the customer enters a configuration value, THE Orchestrator SHALL validate the value against format rules (12-digit numeric for AWS Account IDs, valid CIDR notation for CIDR blocks, valid ARN format for ARNs, UUID format for Azure Subscription IDs) and SHALL reject invalid values with an error message indicating the expected format, allowing the customer to re-enter the value
3. WHEN all configuration values are collected, THE Orchestrator SHALL display a summary of the collected values, masking sensitive values (API tokens, secret keys) to show only the last 4 characters, and request confirmation before proceeding
4. IF the customer rejects the summary, THEN THE Orchestrator SHALL display a numbered list of all configuration fields and allow the customer to select which values to re-enter by number without re-entering all values
5. THE Step_Scripts SHALL NOT prompt the user for interactive input during execution; all required values SHALL be passed as parameters or environment variables from the Orchestrator
6. THE Orchestrator SHALL define a configuration schema per Setup_Type and Scope_Mode combination that specifies all required input fields, their validation rules, and default values where applicable
7. WHEN the configuration schema defines a default value for a field, THE Orchestrator SHALL present the default value to the customer and accept it if the customer provides no input

### Requirement 8: Step Script Output Propagation

**User Story:** As a developer, I want step scripts to output structured values (e.g., VPC ID, Peering ID), so that downstream steps can consume them without requiring additional user input.

#### Acceptance Criteria

1. WHEN a Step_Script creates or reuses a resource, THE Step_Script SHALL write each output value as a single line in the format `OUTPUT:<key>=<value>` to stdout, where `<key>` is an alphanumeric identifier (letters, digits, and underscores, maximum 64 characters) and `<value>` is the resource identifier string (maximum 256 characters)
2. WHEN a Step_Script completes successfully, THE Orchestrator SHALL parse all `OUTPUT:<key>=<value>` lines from the Step_Script stdout and pass them as environment variables to subsequent Step_Scripts that declare a dependency on those keys
3. THE Orchestrator SHALL record all captured step outputs (key-value pairs) in the State_File under the originating step identifier, so that resumed executions can supply outputs from previously completed steps without re-running them
4. IF a Step_Script exits with a non-zero exit code before emitting expected output values, THEN THE Orchestrator SHALL halt execution, log which output keys were not produced, and preserve any outputs that were emitted prior to the failure in the State_File
5. IF a Step_Script emits an output line that does not conform to the `OUTPUT:<key>=<value>` format, THEN THE Orchestrator SHALL ignore the malformed line and log a warning indicating the Step_Script name and the invalid line content

### Requirement 9: Cleanup and Rollback Support

**User Story:** As a customer, I want the ability to tear down resources created by the setup, so that I can cleanly remove JIT infrastructure when needed.

#### Acceptance Criteria

1. WHEN the customer passes a cleanup flag to the Orchestrator, THE Orchestrator SHALL display the list of completed setup steps (including step name and target account) and prompt the customer for confirmation before proceeding with removal
2. WHEN the customer confirms the cleanup prompt, THE Orchestrator SHALL execute cleanup scripts in reverse order of the original setup sequence
3. IF a cleanup step fails, THEN THE Orchestrator SHALL log the failure with the step name and error description to the console output, display the resource identifiers that could not be cleaned up, and continue executing the remaining cleanup steps
4. WHEN all cleanup steps have been attempted, THE Orchestrator SHALL display a summary listing which steps succeeded and which failed with their associated resource identifiers
