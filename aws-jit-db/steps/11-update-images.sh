#!/usr/bin/env bash
# =============================================================================
# Step: Update image version on existing ECS services
# =============================================================================
# Lists JIT database ECS services in the current account and region, lets the
# operator choose which ones to roll, then asks for the image tag.
#
# Service names matched:
#   DAM off: proxysql, proxyserver, query-logging
#   DAM on:  those three, plus postgresql and dam-server
#   A numeric suffix (proxysql-2) is treated as the same service.
#
# The repository path already on the task is kept. Only the tag changes, so a
# pull-through cache URI and a privately synced URI both keep working.
#
# Uses the AWS credentials already in the environment. Does not read or write
# setup state.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Names created by the workload steps. A trailing -N covers extra setups.
SERVICE_NAME_RE='^(proxysql|proxyserver|query-logging|postgresql|dam-server)(-[0-9]+)?$'

# -----------------------------------------------------------------------------
# Region
# -----------------------------------------------------------------------------

_default_region="${AWS_REGION:-}"
if [[ -z "$_default_region" ]]; then
    _state_file="$SCRIPT_DIR/../.state.json"
    if [[ -f "$_state_file" ]]; then
        _default_region=$(jq -r '.config.AWS_REGION // ""' "$_state_file" 2>/dev/null || echo "")
        [[ "$_default_region" == "null" ]] && _default_region=""
    fi
fi
if [[ -z "$_default_region" ]]; then
    _default_region=$(aws configure get region 2>/dev/null || true)
fi
[[ -z "$_default_region" ]] && _default_region="us-east-1"

echo ""
step "AWS Region"
while true; do
    AWS_REGION=$(prompt_with_default "AWS Region" "$_default_region")
    if validate "$AWS_REGION" "region"; then
        break
    fi
    warn "Invalid format. Expected: region"
done
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    error "Current AWS credentials are not valid. Configure the JIT workload account, then re-run."
    exit 1
fi
info "Account: $ACCOUNT_ID | Region: $AWS_REGION"

# -----------------------------------------------------------------------------
# DAM decides which services are rolled
# -----------------------------------------------------------------------------

_state_file="$SCRIPT_DIR/../.state.json"
_dam_default="n"
if [[ -f "$_state_file" ]]; then
    _saved_dam=$(jq -r '.config.ENABLE_DAM // ""' "$_state_file" 2>/dev/null || echo "")
    [[ "$_saved_dam" == "true" ]] && _dam_default="y"
fi

echo ""
step "Database Activity Monitoring"
if prompt_yes_no "Is DAM enabled?" "$_dam_default"; then
    ENABLE_DAM=true
    ALLOWED_JSON='["proxysql","proxyserver","query-logging","postgresql","dam-server"]'
    info "DAM is on — will update proxysql, proxyserver, query-logging, postgresql, and dam-server."
else
    ENABLE_DAM=false
    ALLOWED_JSON='["proxysql","proxyserver","query-logging"]'
    info "DAM is off — will update proxysql, proxyserver, and query-logging only."
fi

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------

# Prints one ARN per line. --no-paginate plus nextToken, so a long account
# list is not cut at the first page.
ecs_list_clusters() {
    local token="" page
    while true; do
        if [[ -n "$token" ]]; then
            page=$(aws ecs list-clusters --no-paginate --next-token "$token" --output json) || return 1
        else
            page=$(aws ecs list-clusters --no-paginate --output json) || return 1
        fi
        echo "$page" | jq -r '.clusterArns[]?'
        token=$(echo "$page" | jq -r '.nextToken // empty')
        [[ -z "$token" ]] && break
    done
}

ecs_list_services() {
    local cluster="$1"
    local token="" page
    while true; do
        if [[ -n "$token" ]]; then
            page=$(aws ecs list-services --no-paginate --cluster "$cluster" --next-token "$token" --output json) || return 1
        else
            page=$(aws ecs list-services --no-paginate --cluster "$cluster" --output json) || return 1
        fi
        echo "$page" | jq -r '.serviceArns[]?'
        token=$(echo "$page" | jq -r '.nextToken // empty')
        [[ -z "$token" ]] && break
    done
}

# Strip a tag or a digest and append the new tag. Hostnames have no port,
# so the only colon in an ECR URI is the tag separator.
retag_image() {
    local img="$1" tag="$2" base suffix
    base="$img"
    if [[ "$base" == *"@sha256:"* ]]; then
        base="${base%%@sha256:*}"
    fi
    if [[ "$base" == *:* ]]; then
        suffix="${base##*:}"
        if [[ "$suffix" != */* ]]; then
            base="${base%:*}"
        fi
    fi
    printf '%s:%s' "$base" "$tag"
}

image_tag_of() {
    local img="$1" base suffix
    base="$img"
    if [[ "$base" == *"@sha256:"* ]]; then
        printf '%s' "<digest>"
        return 0
    fi
    if [[ "$base" == *:* ]]; then
        suffix="${base##*:}"
        if [[ "$suffix" != */* ]]; then
            printf '%s' "$suffix"
            return 0
        fi
    fi
    printf '%s' "<none>"
}

image_repo_of() {
    local img="$1" tagged
    tagged=$(retag_image "$img" "tag")
    printf '%s' "${tagged%:tag}"
}

step "Discover ECS services"

CLUSTERS=()
SERVICES=()
IMAGES=()
TASKDEFS=()
SCANNED=0
SKIPPED=0
DAM_LEFT_OUT=0

clusters_text=$(ecs_list_clusters) || {
    error "Could not list ECS clusters in $AWS_REGION."
    exit 1
}

while IFS= read -r cluster_arn; do
    [[ -z "$cluster_arn" ]] && continue
    cluster="${cluster_arn##*/}"
    status=$(aws ecs describe-clusters --clusters "$cluster" \
        --query 'clusters[0].status' --output text 2>/dev/null || echo "")
    [[ "$status" != "ACTIVE" ]] && continue
    SCANNED=$((SCANNED + 1))

    services_text=$(ecs_list_services "$cluster") || {
        error "Could not list services in cluster $cluster."
        exit 1
    }
    while IFS= read -r service_arn; do
        [[ -z "$service_arn" ]] && continue
        service="${service_arn##*/}"
        if [[ ! "$service" =~ $SERVICE_NAME_RE ]]; then
            continue
        fi
        service_base=$(printf '%s' "$service" | sed -E 's/-[0-9]+$//')
        if [[ "$ENABLE_DAM" != "true" && ( "$service_base" == "postgresql" || "$service_base" == "dam-server" ) ]]; then
            DAM_LEFT_OUT=$((DAM_LEFT_OUT + 1))
            continue
        fi

        svc_json=$(aws ecs describe-services --cluster "$cluster" --services "$service" \
            --query 'services[0].{status:status,task:taskDefinition}' --output json 2>/dev/null || echo '{}')
        svc_status=$(echo "$svc_json" | jq -r '.status // empty')
        taskdef=$(echo "$svc_json" | jq -r '.task // empty')
        if [[ "$svc_status" != "ACTIVE" || -z "$taskdef" || "$taskdef" == "null" ]]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        containers=$(aws ecs describe-task-definition --task-definition "$taskdef" \
            --query 'taskDefinition.containerDefinitions' --output json)
        image=$(echo "$containers" | jq -r --arg svc "$service" --argjson allowed "$ALLOWED_JSON" '
            def base: if test("-[0-9]+$") then sub("-[0-9]+$"; "") else . end;
            [ .[] | select(
                (.name == $svc or .name == ($svc | base))
                and ((.name | base) as $n | $allowed | index($n) != null)
            ) | .image ] | first // empty
        ')
        if [[ -z "$image" ]]; then
            warn "Skipping $cluster/$service — no JIT container image on the task"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        CLUSTERS+=("$cluster")
        SERVICES+=("$service")
        IMAGES+=("$image")
        TASKDEFS+=("$taskdef")
    done <<< "$services_text"
done <<< "$clusters_text"

COUNT=${#SERVICES[@]}
if [[ "$COUNT" -eq 0 ]]; then
    error "No matching ECS services in $AWS_REGION (scanned $SCANNED active cluster(s))."
    if [[ "$ENABLE_DAM" == "true" ]]; then
        error "Expected service names: proxysql, proxyserver, query-logging, postgresql, dam-server."
    else
        error "Expected service names: proxysql, proxyserver, query-logging."
    fi
    exit 1
fi

info "Scanned $SCANNED active cluster(s). Found $COUNT service(s)."
[[ "$SKIPPED" -gt 0 ]] && info "Skipped $SKIPPED service(s) that are not active or have no JIT image."
if [[ "$ENABLE_DAM" != "true" && "$DAM_LEFT_OUT" -gt 0 ]]; then
    info "DAM is off — left postgresql and dam-server unchanged ($DAM_LEFT_OUT service(s))."
fi

echo ""
echo "ECS services:"
echo ""
for i in "${!SERVICES[@]}"; do
    printf '  %d) %s / %s\n' "$((i + 1))" "${CLUSTERS[$i]}" "${SERVICES[$i]}"
    printf '       %s\n' "$(image_tag_of "${IMAGES[$i]}")"
    printf '       %s\n' "$(image_repo_of "${IMAGES[$i]}")"
done
echo ""

# -----------------------------------------------------------------------------
# Choose services, then the tag
# -----------------------------------------------------------------------------

SELECTED_IDX=()
attempts=0
while true; do
    choice=""
    read -erp "Select services to update (numbers separated by commas, or 'all') [all]: " choice
    choice="${choice:-all}"
    choice=$(printf '%s' "$choice" | tr ',' ' ')

    if [[ "$choice" == "all" || "$choice" == "a" || "$choice" == "*" ]]; then
        SELECTED_IDX=()
        for i in "${!SERVICES[@]}"; do
            SELECTED_IDX+=("$i")
        done
        break
    fi

    valid=true
    SELECTED_IDX=()
    for raw in $choice; do
        token=$(printf '%s' "$raw" | tr -d '[:space:]')
        [[ -z "$token" ]] && continue
        if [[ ! "$token" =~ ^[0-9]+$ ]] || [[ "$token" -lt 1 ]] || [[ "$token" -gt "$COUNT" ]]; then
            warn "Invalid selection '$token'. Enter numbers from 1 to $COUNT, or 'all'."
            valid=false
            break
        fi
        idx=$((token - 1))
        already=false
        if [[ ${#SELECTED_IDX[@]} -gt 0 ]]; then
            for seen in "${SELECTED_IDX[@]}"; do
                [[ "$seen" == "$idx" ]] && already=true && break
            done
        fi
        [[ "$already" == true ]] && continue
        SELECTED_IDX+=("$idx")
    done
    if [[ "$valid" == true && ${#SELECTED_IDX[@]} -gt 0 ]]; then
        break
    fi
    if [[ "$valid" == true ]]; then
        warn "Select at least one service."
    fi
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 3 ]]; then
        error "Too many invalid attempts."
        exit 1
    fi
done

echo ""
step "Image tag"
NEW_TAG=""
while true; do
    read -erp "Image tag to deploy (example: v0.3.29-patch): " NEW_TAG
    NEW_TAG=$(printf '%s' "$NEW_TAG" | tr -d '[:space:]')
    if validate_semver_or_latest "$NEW_TAG"; then
        break
    fi
    warn "Enter 'latest' or a version such as v0.3.29 or v0.3.29-patch."
done

echo ""
step "Review"
echo ""
info "Account: $ACCOUNT_ID | Region: $AWS_REGION | Tag: $NEW_TAG"
echo ""
needs_ptc=false
for idx in "${SELECTED_IDX[@]}"; do
    current="${IMAGES[$idx]}"
    updated=$(retag_image "$current" "$NEW_TAG")
    printf '  %s / %s\n' "${CLUSTERS[$idx]}" "${SERVICES[$idx]}"
    printf '    %s\n' "$(image_tag_of "$current") -> $NEW_TAG"
    printf '    %s\n' "$(image_repo_of "$current")"
    if [[ "$current" == */"${CDX_PTC_PREFIX}"/* || "$updated" == */"${CDX_PTC_PREFIX}"/* ]]; then
        needs_ptc=true
    fi
done
echo ""

if ! prompt_yes_no "Apply these image updates?" "n"; then
    info "Cancelled. No services were changed."
    exit 0
fi

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------

if [[ "$needs_ptc" == true ]]; then
    step "Pull-through cache"
    cdx_ensure_pull_through_cache
fi

step "Register task definitions and roll services"

UPDATED=0
for idx in "${SELECTED_IDX[@]}"; do
    cluster="${CLUSTERS[$idx]}"
    service="${SERVICES[$idx]}"
    taskdef="${TASKDEFS[$idx]}"
    info "Updating $cluster/$service"

    described=$(aws ecs describe-task-definition --task-definition "$taskdef" --include TAGS --output json)
    rendered=$(echo "$described" | jq --arg tag "$NEW_TAG" --arg svc "$service" --argjson allowed "$ALLOWED_JSON" '
        def base: if test("-[0-9]+$") then sub("-[0-9]+$"; "") else . end;
        def retag($tag):
            if test("@sha256:") then
                (sub("@sha256:[A-Fa-f0-9]+$"; "") | sub(":[^:/]+$"; "")) + ":" + $tag
            else
                (sub(":[^:/]+$"; "")) + ":" + $tag
            end;
        def is_target:
            (.name | base) as $n | $allowed | index($n) != null;
        . as $root
        | $root.taskDefinition
        | del(
            .taskDefinitionArn, .revision, .status, .requiresAttributes,
            .compatibilities, .registeredAt, .registeredBy, .deregisteredAt
          )
        | .containerDefinitions |= map(
            if is_target then .image |= retag($tag) else . end
          )
        | with_entries(select(.value != null))
        | if (($root.tags // []) | length) > 0 then . + {tags: $root.tags} else . end
    ')

    changed=$(echo "$rendered" | jq -r --argjson old "$(echo "$described" | jq '.taskDefinition.containerDefinitions')" '
        [ .containerDefinitions[].image ] as $new
        | [ $old[].image ] as $prev
        | if $new == $prev then "no" else "yes" end
    ')

    if [[ "$changed" == "yes" ]]; then
        payload=$(mktemp "${TMPDIR:-/tmp}/cdx-td.XXXXXX")
        printf '%s\n' "$rendered" > "$payload"
        if ! new_td=$(aws ecs register-task-definition --cli-input-json "file://${payload}" \
            --query 'taskDefinition.taskDefinitionArn' --output text); then
            rm -f "$payload"
            error "Failed to register a new task definition for $cluster/$service"
            exit 1
        fi
        rm -f "$payload"
        aws ecs update-service --cluster "$cluster" --service "$service" \
            --task-definition "$new_td" --force-new-deployment > /dev/null
        ok "$cluster/$service -> $(image_tag_of "$(retag_image "${IMAGES[$idx]}" "$NEW_TAG")") ($new_td)"
    else
        aws ecs update-service --cluster "$cluster" --service "$service" \
            --force-new-deployment > /dev/null
        ok "$cluster/$service already on $NEW_TAG — forced a new deployment"
    fi
    UPDATED=$((UPDATED + 1))
done

step "Wait for services"
info "Waiting until the selected services are stable. This can take a few minutes."

# services-stable accepts services from one cluster per call.
SEEN_CLUSTERS=()
for idx in "${SELECTED_IDX[@]}"; do
    cluster="${CLUSTERS[$idx]}"
    seen=false
    if [[ ${#SEEN_CLUSTERS[@]} -gt 0 ]]; then
        for previous in "${SEEN_CLUSTERS[@]}"; do
            [[ "$previous" == "$cluster" ]] && seen=true && break
        done
    fi
    [[ "$seen" == true ]] && continue
    SEEN_CLUSTERS+=("$cluster")

    names=()
    for j in "${SELECTED_IDX[@]}"; do
        [[ "${CLUSTERS[$j]}" == "$cluster" ]] && names+=("${SERVICES[$j]}")
    done
    if aws ecs wait services-stable --cluster "$cluster" --services "${names[@]}"; then
        ok "Stable: $cluster (${names[*]})"
    else
        error "Timed out waiting for $cluster (${names[*]})."
        error "The new task definition is registered. Check the service events in the ECS console."
        exit 1
    fi
done

echo ""
ok "Updated $UPDATED service(s) to $NEW_TAG"
echo "OUTPUT:IMAGE_TAG=${NEW_TAG}"
echo "OUTPUT:UPDATED_COUNT=${UPDATED}"
