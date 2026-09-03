#!/usr/bin/env bash
# =============================================================================
# Step: Extend Role Trust Policy (DB Account)
# =============================================================================
# Run in the DATABASE account. Updates the trust policy of the cross-account
# role to allow assumption from the ECS task role in the JIT workload account.
#
# Required env vars:
#   AWS_REGION, JIT_ACCOUNT_ID
#
# Outputs:
#   OUTPUT:TRUST_UPDATED=true
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION JIT_ACCOUNT_ID

# =============================================================================
# CONFIGURATION
# =============================================================================

PROJECT_NAME="${PROJECT_NAME:-cdx-jit-db}"
ECS_ROLE_NAME="${PROJECT_NAME}-ECSRole"
# The ARN of the ECS task role in the JIT workload account
ECS_TASK_ROLE_ARN="arn:aws:iam::${JIT_ACCOUNT_ID}:role/${ECS_ROLE_NAME}"

info "DB Account: $(aws sts get-caller-identity --query Account --output text)"
info "JIT Account: $JIT_ACCOUNT_ID"
info "ECS Task Role: $ECS_TASK_ROLE_ARN"

# =============================================================================
# RESOLVE CROSS-ACCOUNT ROLE(S)
# =============================================================================
# Operate on the same existing role(s) that step 05 discovered. Step 05 exports
# CROSS_ACCOUNT_ROLE_NAMES (space-separated). Fall back to discovery here so the
# step can also be run standalone.

ROLES=()
if [[ -n "${CROSS_ACCOUNT_ROLE_NAMES:-}" ]]; then
    read -ra ROLES <<< "$CROSS_ACCOUNT_ROLE_NAMES"
elif [[ -n "${CROSS_ACCOUNT_ROLE_NAME:-}" ]]; then
    ROLES=("$CROSS_ACCOUNT_ROLE_NAME")
else
    while IFS= read -r rn; do
        [[ -n "$rn" ]] && ROLES+=("$rn")
    done < <(aws iam list-roles \
        --query "Roles[?contains(RoleName, 'role_cross_accnt')].RoleName" \
        --output text 2>/dev/null | tr '\t' '\n')
    if [[ ${#ROLES[@]} -eq 0 ]] && aws iam get-role --role-name "cdx-jit-db-cross-account-role" > /dev/null 2>&1; then
        ROLES=("cdx-jit-db-cross-account-role")
    fi
fi

if [[ ${#ROLES[@]} -eq 0 ]]; then
    error "No cross-account role found. Run step 05 first (it discovers the role)."
    exit 1
fi
info "Cross-account role(s): ${ROLES[*]}"

# =============================================================================
# UPDATE TRUST POLICY ON EACH ROLE
# =============================================================================

for ROLE_NAME in "${ROLES[@]}"; do
    step "Update Trust Policy — $ROLE_NAME"

    CURRENT_TRUST=$(aws iam get-role --role-name "$ROLE_NAME" \
        --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)

    if [[ -z "$CURRENT_TRUST" ]]; then
        warn "Role $ROLE_NAME not found — skipping."; continue
    fi

    # Sanitize: remove stale role/user unique IDs (AROA/AIDA prefixes) from AWS
    # principals. These appear when a referenced role was deleted and recreated —
    # AWS rewrites the ARN to the raw ID, which then fails validation on the next
    # update-assume-role-policy call. We strip the bad IDs, and drop any statement
    # left with an empty principal.
    CURRENT_TRUST=$(echo "$CURRENT_TRUST" | jq '
        .Statement = [
            .Statement[]
            | if (.Principal.AWS != null) then
                .Principal.AWS = (
                    if (.Principal.AWS | type) == "array"
                    then [ .Principal.AWS[] | select(test("^(AROA|AIDA)") | not) ]
                    else (if (.Principal.AWS | test("^(AROA|AIDA)")) then empty else .Principal.AWS end)
                    end
                )
              else . end
            | select((.Principal.AWS == null) or ((.Principal.AWS | type) != "array") or ((.Principal.AWS | length) > 0))
        ]')

    # Is the ECS task role already trusted?
    ALREADY_TRUSTED=$(echo "$CURRENT_TRUST" | jq -r \
        --arg arn "$ECS_TASK_ROLE_ARN" \
        '.Statement[] | select(.Principal.AWS != null) |
         if (.Principal.AWS | type) == "array" then
             .Principal.AWS[] | select(. == $arn)
         else
             select(.Principal.AWS == $arn) | .Principal.AWS
         end' 2>/dev/null)

    if [[ -n "$ALREADY_TRUSTED" ]]; then
        ok "Trust already includes: $ECS_TASK_ROLE_ARN"
    else
        NEW_TRUST=$(echo "$CURRENT_TRUST" | jq \
            --arg arn "$ECS_TASK_ROLE_ARN" \
            '.Statement += [{
                "Effect": "Allow",
                "Principal": {"AWS": $arn},
                "Action": "sts:AssumeRole"
            }]')
        aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
            --policy-document "$NEW_TRUST"
        ok "Trust updated — added $ECS_TASK_ROLE_ARN"
    fi

    VERIFIED=$(aws iam get-role --role-name "$ROLE_NAME" \
        --query 'Role.AssumeRolePolicyDocument.Statement[*].Principal.AWS' --output text 2>/dev/null)
    info "Trusted principals: $VERIFIED"
done

# =============================================================================
# OUTPUT
# =============================================================================

ok "Trust policy extension complete"
echo "OUTPUT:TRUST_UPDATED=true"
