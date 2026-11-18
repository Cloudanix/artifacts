#!/usr/bin/env bash
# =============================================================================
# Stop or delete Cloudanix ECS clusters in the current AWS account
# =============================================================================
# Lists active clusters whose name contains "cdx" or "jit", shows how many
# tasks are running, and asks which ones to stop. The prompt accepts list
# numbers, "all", or cluster names. A typed name is used even when it is
# not in the list, as long as that cluster is active in this region.
# Stopping sets every service's desired count to 0 and stops remaining
# tasks, then waits until the running count is 0. The cluster and its
# task definitions stay.
#
# A second prompt asks whether to delete those clusters. Deleting removes
# the services, deregisters the task definition families they use, and
# deletes the cluster. Nothing else in the account is touched.
#
# Uses the AWS credentials already in the environment. Does not read or
# write setup state.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

CLUSTER_NAME_RE='[Cc][Dd][Xx]|[Jj][Ii][Tt]'
WAIT_SECONDS=600
POLL_SECONDS=10

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
    local cluster="$1" token="" page
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

ecs_list_running_tasks() {
    local cluster="$1" token="" page
    while true; do
        if [[ -n "$token" ]]; then
            page=$(aws ecs list-tasks --no-paginate --cluster "$cluster" --desired-status RUNNING --next-token "$token" --output json) || return 1
        else
            page=$(aws ecs list-tasks --no-paginate --cluster "$cluster" --desired-status RUNNING --output json) || return 1
        fi
        echo "$page" | jq -r '.taskArns[]?'
        token=$(echo "$page" | jq -r '.nextToken // empty')
        [[ -z "$token" ]] && break
    done
}

running_count() {
    aws ecs describe-clusters --clusters "$1" \
        --query 'clusters[0].runningTasksCount' --output text 2>/dev/null || echo "0"
}

wait_until_stopped() {
    local cluster="$1" started now count
    started=$(date +%s)
    while true; do
        count=$(running_count "$cluster")
        [[ "$count" == "None" || -z "$count" ]] && count=0
        if [[ "$count" -eq 0 ]]; then
            ok "$cluster has 0 running tasks"
            return 0
        fi
        now=$(date +%s)
        if (( now - started >= WAIT_SECONDS )); then
            error "$cluster still has $count running task(s) after ${WAIT_SECONDS}s"
            return 1
        fi
        info "$cluster still has $count running task(s). Checking again in ${POLL_SECONDS}s."
        sleep "$POLL_SECONDS"
    done
}

# -----------------------------------------------------------------------------
# Region and account
# -----------------------------------------------------------------------------

_default_region="${AWS_REGION:-}"
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
    error "Current AWS credentials are not valid."
    exit 1
fi
info "Account: $ACCOUNT_ID | Region: $AWS_REGION"

# -----------------------------------------------------------------------------
# Active cdx* clusters
# -----------------------------------------------------------------------------

echo ""
step "Cloudanix ECS clusters"
NAMES=()
RUNNING=()
SERVICES_N=()

while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    name="${arn##*/}"
    [[ "$name" =~ $CLUSTER_NAME_RE ]] || continue
    desc=$(aws ecs describe-clusters --clusters "$name" \
        --query 'clusters[0].{status:status,running:runningTasksCount,active:activeServicesCount}' \
        --output json 2>/dev/null || echo '{}')
    status=$(echo "$desc" | jq -r '.status // empty')
    [[ "$status" == "ACTIVE" ]] || continue
    NAMES+=("$name")
    RUNNING+=("$(echo "$desc" | jq -r '.running // 0')")
    SERVICES_N+=("$(echo "$desc" | jq -r '.active // 0')")
done < <(ecs_list_clusters)

COUNT=${#NAMES[@]}
if [[ "$COUNT" -eq 0 ]]; then
    info "No active ECS clusters starting with cdx in $AWS_REGION."
    exit 0
fi

echo ""
printf '  %-4s %-42s %10s %10s\n' "#" "Cluster" "Running" "Services"
for i in "${!NAMES[@]}"; do
    printf '  %-4s %-42s %10s %10s\n' "$((i + 1))" "${NAMES[$i]}" "${RUNNING[$i]}" "${SERVICES_N[$i]}"
done
echo ""
info "Enter list numbers, 'all', or cluster names separated by commas."
info "A name not in the list is used when that cluster is active here."
info "Example: 1,2   or   jit-db-cluster-2, jit-db-cluster-3"
echo ""

select_index() {
    local want="$1" seen
    already=false
    if [[ ${#SELECTED[@]} -gt 0 ]]; then
        for seen in "${SELECTED[@]}"; do
            [[ "$seen" == "$want" ]] && already=true && break
        done
    fi
    [[ "$already" == true ]] && return 0
    SELECTED+=("$want")
}

lookup_listed() {
    local token="$1" i listed
    local lower
    lower=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')
    for i in "${!NAMES[@]}"; do
        [[ "${NAMES[$i]}" == "$token" ]] && echo "$i" && return 0
    done
    for i in "${!NAMES[@]}"; do
        listed=$(printf '%s' "${NAMES[$i]}" | tr '[:upper:]' '[:lower:]')
        [[ "$listed" == "$lower" ]] && echo "$i" && return 0
    done
    return 1
}

add_named_cluster() {
    local name="$1" desc status
    name="${name##*/}"
    desc=$(aws ecs describe-clusters --clusters "$name" \
        --query 'clusters[0].{status:status,running:runningTasksCount,active:activeServicesCount}' \
        --output json 2>/dev/null || echo '{}')
    status=$(echo "$desc" | jq -r '.status // empty')
    if [[ "$status" != "ACTIVE" ]]; then
        warn "No active cluster named '$name' in $AWS_REGION." >&2
        return 1
    fi
    NAMES+=("$name")
    RUNNING+=("$(echo "$desc" | jq -r '.running // 0')")
    SERVICES_N+=("$(echo "$desc" | jq -r '.active // 0')")
    echo $((${#NAMES[@]} - 1))
}

SELECTED=()
attempts=0
while true; do
    choice=""
    read -erp "Clusters to stop (numbers, names, or 'all') [all]: " choice
    choice="${choice:-all}"
    choice=$(printf '%s' "$choice" | tr ',' ' ')

    if [[ "$choice" == "all" || "$choice" == "a" || "$choice" == "*" ]]; then
        SELECTED=()
        for i in $(seq 0 $((COUNT - 1))); do
            SELECTED+=("$i")
        done
        break
    fi

    valid=true
    SELECTED=()
    for raw in $choice; do
        token=$(printf '%s' "$raw" | tr -d '[:space:]')
        [[ -z "$token" ]] && continue
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            if [[ "$token" -lt 1 || "$token" -gt "$COUNT" ]]; then
                warn "Invalid selection '$token'. Enter numbers from 1 to $COUNT, 'all', or a cluster name."
                valid=false
                break
            fi
            select_index $((token - 1))
            continue
        fi
        if idx=$(lookup_listed "$token"); then
            select_index "$idx"
            continue
        fi
        if idx=$(add_named_cluster "$token"); then
            info "Added ${NAMES[$idx]} (running ${RUNNING[$idx]})"
            select_index "$idx"
            continue
        fi
        valid=false
        break
    done
    if [[ "$valid" == true && ${#SELECTED[@]} -gt 0 ]]; then
        break
    fi
    [[ "$valid" == true ]] && warn "Select at least one cluster."
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 3 ]]; then
        error "Too many invalid attempts."
        exit 1
    fi
done

echo ""
echo "Selected:"
for idx in "${SELECTED[@]}"; do
    echo "  ${NAMES[$idx]}  (running ${RUNNING[$idx]})"
done
echo ""

if ! prompt_yes_no "Stop all tasks on the selected clusters?" "n"; then
    info "Nothing stopped."
    exit 0
fi

# -----------------------------------------------------------------------------
# Stop: desired count 0, then stop anything still running
# -----------------------------------------------------------------------------

echo ""
step "Stop tasks"
for idx in "${SELECTED[@]}"; do
    cluster="${NAMES[$idx]}"
    info "Stopping $cluster"
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        aws ecs update-service --cluster "$cluster" --service "$svc" --desired-count 0 >/dev/null
        ok "Desired count 0: ${svc##*/}"
    done < <(ecs_list_services "$cluster")

    while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        aws ecs stop-task --cluster "$cluster" --task "$task" \
            --reason "Stopped by stop-clusters.sh" >/dev/null || true
    done < <(ecs_list_running_tasks "$cluster")

    wait_until_stopped "$cluster"
done

# -----------------------------------------------------------------------------
# Optional delete
# -----------------------------------------------------------------------------

echo ""
if ! prompt_yes_no "Delete the selected clusters and deregister their task definitions?" "n"; then
    info "Clusters were stopped and left in place."
    exit 0
fi

echo ""
step "Delete clusters"
for idx in "${SELECTED[@]}"; do
    cluster="${NAMES[$idx]}"
    info "Deleting $cluster"

    FAMILIES=()
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        td=$(aws ecs describe-services --cluster "$cluster" --services "$svc" \
            --query 'services[0].taskDefinition' --output text 2>/dev/null || echo "")
        if [[ -n "$td" && "$td" != "None" ]]; then
            family="${td##*/}"
            family="${family%%:*}"
            seen=false
            if [[ ${#FAMILIES[@]} -gt 0 ]]; then
                for have in "${FAMILIES[@]}"; do
                    [[ "$have" == "$family" ]] && seen=true && break
                done
            fi
            [[ "$seen" == false ]] && FAMILIES+=("$family")
        fi
        aws ecs delete-service --cluster "$cluster" --service "$svc" --force >/dev/null
        ok "Service deleted: ${svc##*/}"
    done < <(ecs_list_services "$cluster")

    started=$(date +%s)
    while true; do
        left=$(ecs_list_services "$cluster" | grep -c . || true)
        [[ -z "$left" ]] && left=0
        count=$(running_count "$cluster")
        [[ "$count" == "None" || -z "$count" ]] && count=0
        if [[ "$left" -eq 0 && "$count" -eq 0 ]]; then
            break
        fi
        now=$(date +%s)
        if (( now - started >= WAIT_SECONDS )); then
            error "$cluster still has services or running tasks. Cluster was not deleted."
            continue 2
        fi
        info "$cluster still has $left service(s) and $count running task(s)."
        sleep "$POLL_SECONDS"
    done

    if [[ ${#FAMILIES[@]} -gt 0 ]]; then
        for family in "${FAMILIES[@]}"; do
            while IFS= read -r td; do
                [[ -z "$td" ]] && continue
                aws ecs deregister-task-definition --task-definition "$td" >/dev/null
                ok "Task definition deregistered: ${td##*/}"
            done < <(aws ecs list-task-definitions --family-prefix "$family" --status ACTIVE \
                --query 'taskDefinitionArns[]' --output text | tr '\t' '\n' | grep -E "/${family}:[0-9]+$" || true)
        done
    else
        info "No task definitions were attached to $cluster"
    fi

    aws ecs delete-cluster --cluster "$cluster" >/dev/null
    ok "Cluster deleted: $cluster"
done

echo ""
ok "Selected clusters are deleted."
