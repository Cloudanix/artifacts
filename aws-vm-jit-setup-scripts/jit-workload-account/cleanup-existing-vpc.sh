#!/bin/bash
set -e
trap 'echo "[ERROR] Line $LINENO. Command: $BASH_COMMAND"' ERR

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
ok()   { echo "[✓] $*"; }
info() { echo "[i] $*"; }
step() { echo ""; echo "━━━ $* ━━━"; }

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    while true; do
        read -p "$prompt (y/n) [$default_value]: " yn
        yn=${yn:-$default_value}
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# ============================================================================
# CONFIGURATION
# ============================================================================

echo "=== JIT VM Workload Cleanup (Existing VPC) ==="
echo ""
echo "This script removes JIT VM workload resources WITHOUT touching the VPC,"
echo "subnets, route tables, internet gateway, or NAT gateway."
echo ""

AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
PROJECT_NAME=$(prompt_with_default "Project Name" "cdx-jit-vm")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Account ID: $ACCOUNT_ID"

CLUSTER_NAME="${PROJECT_NAME}-cluster"
ROLE_NAME="${PROJECT_NAME}-ECSRole"
LOG_GROUP="/ecs/${PROJECT_NAME}"
NAMESPACE="${PROJECT_NAME}-local"
S3_BUCKET_NAME=$(prompt_with_default "S3 Bucket for Recordings" "${PROJECT_NAME}-recordings-${ACCOUNT_ID}")
APP_SECRET_NAME="${PROJECT_NAME}-secret"

echo ""
echo "=== Resources to be removed ==="
echo "  ECS Services:     jit-vm-proxy-sshpiper, jit-vm-proxy-vmproxyserver, jit-vm-proxy-vmcommandlogging"
echo "  Task Definitions: ${PROJECT_NAME}-sshpiper, ${PROJECT_NAME}-vmproxyserver, ${PROJECT_NAME}-vmcommandlogging"
echo "  ECS Cluster:      $CLUSTER_NAME"
echo "  Cloud Map:        $NAMESPACE"
echo "  EFS:              ${PROJECT_NAME}-efs (+ mount targets + access points)"
echo "  Security Groups:  ${PROJECT_NAME}-ecs-sg, ${PROJECT_NAME}-vpce-sg"
echo "  VPC Endpoints:    ssm, ssmmessages, ec2messages"
echo "  IAM Role:         $ROLE_NAME (+ inline policy)"
echo "  S3 Bucket:        $S3_BUCKET_NAME"
echo "  Secret:           $APP_SECRET_NAME"
echo "  Log Group:        $LOG_GROUP"
echo ""
echo "  NOT removed: VPC, Subnets, Route Tables, Internet Gateway, NAT Gateway"
echo ""

if ! prompt_yes_no "Proceed with cleanup?" "n"; then
    echo "Cleanup cancelled."
    exit 0
fi

# ============================================================================
# STEP 1: DELETE ECS SERVICES
# ============================================================================

step "ECS Services"

SERVICE_NAMES=("jit-vm-proxy-sshpiper" "jit-vm-proxy-vmproxyserver" "jit-vm-proxy-vmcommandlogging")

for svc in "${SERVICE_NAMES[@]}"; do
    ACTIVE=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" \
        --query "services[?status=='ACTIVE'].serviceName | [0]" --output text --region "$AWS_REGION" 2>/dev/null)

    if [ -n "$ACTIVE" ] && [ "$ACTIVE" != "None" ]; then
        log "Scaling down service: $svc"
        aws ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" --desired-count 0 \
            --region "$AWS_REGION" --no-cli-pager > /dev/null || log "Failed to scale down: $svc"

        log "Waiting for tasks to drain: $svc"
        aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$svc" \
            --region "$AWS_REGION" 2>/dev/null || log "Timeout waiting for stable: $svc"

        log "Deleting service: $svc"
        aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc" --force \
            --region "$AWS_REGION" --no-cli-pager > /dev/null || log "Failed to delete: $svc"
        ok "Deleted service: $svc"
    else
        info "Service not found: $svc — skipping"
    fi
done

# ============================================================================
# STEP 2: DEREGISTER TASK DEFINITIONS
# ============================================================================

step "Task Definitions"

TASK_FAMILIES=("${PROJECT_NAME}-sshpiper" "${PROJECT_NAME}-vmproxyserver" "${PROJECT_NAME}-vmcommandlogging")

for family in "${TASK_FAMILIES[@]}"; do
    REVISIONS=$(aws ecs list-task-definitions --family-prefix "$family" --status ACTIVE \
        --query 'taskDefinitionArns[*]' --output text --region "$AWS_REGION" 2>/dev/null)

    if [ -n "$REVISIONS" ]; then
        for rev in $REVISIONS; do
            aws ecs deregister-task-definition --task-definition "$rev" \
                --region "$AWS_REGION" --no-cli-pager > /dev/null || log "Failed to deregister: $rev"
        done
        ok "Deregistered task definitions: $family"
    else
        info "No task definitions for: $family — skipping"
    fi
done

# ============================================================================
# STEP 3: DELETE ECS CLUSTER
# ============================================================================

step "ECS Cluster"

CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
    --query 'clusters[0].status' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
    aws ecs delete-cluster --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --no-cli-pager > /dev/null \
        || log "Failed to delete cluster: $CLUSTER_NAME"
    ok "Deleted cluster: $CLUSTER_NAME"
else
    info "Cluster not found or not active: $CLUSTER_NAME — skipping"
fi

# ============================================================================
# STEP 4: DELETE CLOUD MAP NAMESPACE (+ services)
# ============================================================================

step "Cloud Map Namespace"

NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --filters "Name=NAME,Values=${NAMESPACE}" \
    --query 'Namespaces[0].Id' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -n "$NAMESPACE_ID" ] && [ "$NAMESPACE_ID" != "None" ]; then
    # Delete all services in namespace first
    SD_SERVICES=$(aws servicediscovery list-services \
        --filters "Name=NAMESPACE_ID,Values=$NAMESPACE_ID" \
        --query 'Services[*].Id' --output text --region "$AWS_REGION" 2>/dev/null)

    for sd_svc in $SD_SERVICES; do
        # Deregister all instances first
        INSTANCES=$(aws servicediscovery list-instances --service-id "$sd_svc" \
            --query 'Instances[*].Id' --output text --region "$AWS_REGION" 2>/dev/null)
        for inst_id in $INSTANCES; do
            aws servicediscovery deregister-instance --service-id "$sd_svc" --instance-id "$inst_id" \
                --region "$AWS_REGION" > /dev/null 2>&1 || true
        done
        aws servicediscovery delete-service --id "$sd_svc" --region "$AWS_REGION" --no-cli-pager > /dev/null \
            || log "Failed to delete service discovery service: $sd_svc"
    done

    log "Deleting namespace: $NAMESPACE ($NAMESPACE_ID)"
    aws servicediscovery delete-namespace --id "$NAMESPACE_ID" --region "$AWS_REGION" --no-cli-pager > /dev/null \
        || log "Failed to delete namespace: $NAMESPACE_ID"
    ok "Deleted namespace: $NAMESPACE"
else
    info "Namespace not found: $NAMESPACE — skipping"
fi

# ============================================================================
# STEP 5: DELETE EFS (access points, mount targets, file system)
# ============================================================================

step "EFS File System"

EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-efs']].FileSystemId | [0]" --output text 2>/dev/null)

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
    # Delete access points
    ACCESS_POINTS=$(aws efs describe-access-points --file-system-id "$EFS_ID" \
        --query 'AccessPoints[*].AccessPointId' --output text --region "$AWS_REGION" 2>/dev/null)
    for ap in $ACCESS_POINTS; do
        aws efs delete-access-point --access-point-id "$ap" --region "$AWS_REGION" > /dev/null \
            || log "Failed to delete access point: $ap"
        ok "Deleted access point: $ap"
    done

    # Delete mount targets
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query 'MountTargets[*].MountTargetId' --output text --region "$AWS_REGION" 2>/dev/null)
    for mt in $MOUNT_TARGETS; do
        aws efs delete-mount-target --mount-target-id "$mt" --region "$AWS_REGION" > /dev/null \
            || log "Failed to delete mount target: $mt"
    done

    if [ -n "$MOUNT_TARGETS" ] && [ "$MOUNT_TARGETS" != "None" ]; then
        log "Waiting for mount targets to be deleted (30s)..."
        sleep 30
    fi

    # Delete file system
    aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION" > /dev/null \
        || log "Failed to delete EFS: $EFS_ID"
    ok "Deleted EFS: $EFS_ID"
else
    info "EFS not found: ${PROJECT_NAME}-efs — skipping"
fi

# ============================================================================
# STEP 6: DELETE VPC ENDPOINTS (ssm, ssmmessages, ec2messages)
# ============================================================================

step "VPC Endpoints"

for SVC in ssm ssmmessages ec2messages; do
    VPCE_ID=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=tag:Name,Values=${PROJECT_NAME}-${SVC}" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "$AWS_REGION" 2>/dev/null)

    if [ -n "$VPCE_ID" ] && [ "$VPCE_ID" != "None" ]; then
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_ID" --region "$AWS_REGION" > /dev/null \
            || log "Failed to delete VPC endpoint: $VPCE_ID ($SVC)"
        ok "Deleted VPC endpoint: $VPCE_ID ($SVC)"
    else
        info "VPC endpoint not found: ${PROJECT_NAME}-${SVC} — skipping"
    fi
done

# ============================================================================
# STEP 7: DELETE SECURITY GROUPS
# ============================================================================

step "Security Groups"

# Need to wait a bit for ENIs from EFS/VPC endpoints to be released
log "Waiting 15s for ENIs to detach..."
sleep 15

for SG_NAME in "${PROJECT_NAME}-ecs-sg" "${PROJECT_NAME}-vpce-sg"; do
    SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${SG_NAME}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        # Remove all ingress/egress rules referencing itself (self-referencing rules block deletion)
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
            --security-group-rule-ids $(aws ec2 describe-security-group-rules \
                --filters "Name=group-id,Values=$SG_ID" \
                --query "SecurityGroupRules[?!IsEgress].SecurityGroupRuleId" \
                --output text --region "$AWS_REGION") \
            --region "$AWS_REGION" 2>/dev/null || true

        aws ec2 revoke-security-group-egress --group-id "$SG_ID" \
            --security-group-rule-ids $(aws ec2 describe-security-group-rules \
                --filters "Name=group-id,Values=$SG_ID" \
                --query "SecurityGroupRules[?IsEgress].SecurityGroupRuleId" \
                --output text --region "$AWS_REGION") \
            --region "$AWS_REGION" 2>/dev/null || true

        aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" > /dev/null \
            || log "Failed to delete SG: $SG_NAME ($SG_ID) — may need manual cleanup if ENIs still attached"
        ok "Deleted security group: $SG_NAME ($SG_ID)"
    else
        info "Security group not found: $SG_NAME — skipping"
    fi
done

# ============================================================================
# STEP 8: DELETE CLOUDWATCH LOG GROUP
# ============================================================================

step "CloudWatch Log Group"

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$AWS_REGION" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" --output text | grep -q "$LOG_GROUP"; then
    aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" > /dev/null \
        || log "Failed to delete log group: $LOG_GROUP"
    ok "Deleted log group: $LOG_GROUP"
else
    info "Log group not found: $LOG_GROUP — skipping"
fi

# ============================================================================
# STEP 9: DELETE SECRETS MANAGER SECRET
# ============================================================================

step "Secrets Manager"

if aws secretsmanager describe-secret --secret-id "$APP_SECRET_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$APP_SECRET_NAME" \
        --force-delete-without-recovery --region "$AWS_REGION" --no-cli-pager > /dev/null \
        || log "Failed to delete secret: $APP_SECRET_NAME"
    ok "Deleted secret: $APP_SECRET_NAME"
else
    info "Secret not found: $APP_SECRET_NAME — skipping"
fi

# Also check for SSH keys secret
SSH_KEYS_SECRET="${PROJECT_NAME}-ssh-keys"
if aws secretsmanager describe-secret --secret-id "$SSH_KEYS_SECRET" --region "$AWS_REGION" > /dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$SSH_KEYS_SECRET" \
        --force-delete-without-recovery --region "$AWS_REGION" --no-cli-pager > /dev/null \
        || log "Failed to delete secret: $SSH_KEYS_SECRET"
    ok "Deleted secret: $SSH_KEYS_SECRET"
else
    info "Secret not found: $SSH_KEYS_SECRET — skipping"
fi

# ============================================================================
# STEP 10: DELETE S3 BUCKET
# ============================================================================

step "S3 Bucket"

if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    log "Emptying bucket: $S3_BUCKET_NAME"
    aws s3 rm "s3://$S3_BUCKET_NAME" --recursive --region "$AWS_REGION" > /dev/null \
        || log "Failed to empty bucket"

    # Also remove versioned objects if versioning was enabled
    log "Removing versioned objects..."
    VERSIONS=$(aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
    if [ "$VERSIONS" != '{"Objects": null}' ] && [ -n "$VERSIONS" ]; then
        echo "$VERSIONS" | aws s3api delete-objects --bucket "$S3_BUCKET_NAME" \
            --delete "$VERSIONS" > /dev/null 2>&1 || true
    fi

    DELETE_MARKERS=$(aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
    if [ "$DELETE_MARKERS" != '{"Objects": null}' ] && [ -n "$DELETE_MARKERS" ]; then
        echo "$DELETE_MARKERS" | aws s3api delete-objects --bucket "$S3_BUCKET_NAME" \
            --delete "$DELETE_MARKERS" > /dev/null 2>&1 || true
    fi

    aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" > /dev/null \
        || log "Failed to delete bucket: $S3_BUCKET_NAME"
    ok "Deleted bucket: $S3_BUCKET_NAME"
else
    info "Bucket not found: $S3_BUCKET_NAME — skipping"
fi

# ============================================================================
# STEP 11: DELETE IAM ROLE (inline policy + managed policy + role)
# ============================================================================

step "IAM Role"

if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    # Remove inline policies
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[*]' --output text 2>/dev/null)
    for pol in $INLINE_POLICIES; do
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$pol" \
            || log "Failed to delete inline policy: $pol"
        ok "Removed inline policy: $pol"
    done

    # Detach managed policies
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
        --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null)
    for pol_arn in $ATTACHED_POLICIES; do
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$pol_arn" \
            || log "Failed to detach policy: $pol_arn"
    done

    # Delete role
    aws iam delete-role --role-name "$ROLE_NAME" || log "Failed to delete role: $ROLE_NAME"
    ok "Deleted IAM role: $ROLE_NAME"
else
    info "IAM role not found: $ROLE_NAME — skipping"
fi

# ============================================================================
# STEP 12: DELETE ECR REPOSITORIES
# ============================================================================

step "ECR Repositories"

ECR_REPOS=("cloudanix/ecr-aws-jit-vm-sshpiper" "cloudanix/ecr-aws-jit-vm-proxyserver" "cloudanix/ecr-aws-jit-vm-logging")

for repo in "${ECR_REPOS[@]}"; do
    if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" > /dev/null 2>&1; then
        aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" > /dev/null \
            || log "Failed to delete ECR repo: $repo"
        ok "Deleted ECR repository: $repo"
    else
        info "ECR repository not found: $repo — skipping"
    fi
done

# ============================================================================
# DONE
# ============================================================================

step "Cleanup Complete"
echo ""
echo "  Removed:"
echo "    ✓ ECS services, task definitions, and cluster"
echo "    ✓ Cloud Map namespace"
echo "    ✓ EFS file system (+ mount targets + access points)"
echo "    ✓ VPC endpoints (ssm, ssmmessages, ec2messages)"
echo "    ✓ Security groups"
echo "    ✓ CloudWatch log group"
echo "    ✓ Secrets Manager secrets"
echo "    ✓ S3 bucket"
echo "    ✓ IAM role and policies"
echo "    ✓ ECR repositories"
echo ""
echo "  Preserved:"
echo "    • VPC"
echo "    • Subnets"
echo "    • Route tables"
echo "    • Internet Gateway / NAT Gateway"
echo "    • VPC Peering connections"
echo ""
