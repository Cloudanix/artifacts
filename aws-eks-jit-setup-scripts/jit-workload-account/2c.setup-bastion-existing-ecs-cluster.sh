#!/bin/bash
set -e
set -u

###############################################################################
# EKS JIT Bastion — ECS Service Setup (extends existing cdx-jit-db cluster)
#
# This script adds an EKS bastion ECS service to the EXISTING jit-db ECS
# cluster. It does NOT create a new VPC or ECS cluster.
#
# What it creates:
#   1. Dedicated IAM role (cdx-jit-k8s-bastion-ECSRole) with ECS Exec + EKS permissions
#   2. CloudWatch Log Group for bastion
#   3. Security group rule for bastion (port 443 from VPC for SSM/ECS Exec)
#   4. Task definition for the bastion container
#   5. ECS Service with ECS Exec enabled + tag propagation
#
# Prerequisites:
#   - cdx-jit-db cluster already deployed (2.1.install-workloads-new-vpc.sh)
#   - VPC, subnets, NAT Gateway, security group already exist
###############################################################################

handle_error() {
    local exit_code=$?
    echo "[ERROR] Line $1, exit code $exit_code"
    exit $exit_code
}
trap 'handle_error $LINENO' ERR

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

# ============================================================================
# CONFIGURATION
# ============================================================================

echo "=== EKS JIT Bastion — ECS Service Setup ==="
echo ""
echo "This extends your existing cdx-jit-db ECS cluster with a bastion service"
echo "for EKS JIT access (replaces EC2 bastion with ECS Fargate)."
echo ""

AWS_REGION=$(prompt_with_default "AWS Region" "us-east-1")
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Existing infrastructure references
ECS_CLUSTER_NAME=$(prompt_with_default "Existing ECS Cluster Name" "cdx-jit-db-cluster")

# Bastion-specific IAM role (created fresh by this script)
BASTION_ROLE_NAME="cdx-jit-k8s-bastion-ECSRole"

# Discover VPC from cluster's existing services
info "Discovering existing infrastructure from cluster..."
EXISTING_SERVICE=$(aws ecs list-services --cluster "$ECS_CLUSTER_NAME" --query 'serviceArns[0]' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -z "$EXISTING_SERVICE" ] || [ "$EXISTING_SERVICE" = "None" ]; then
    echo "ERROR: No services found in cluster $ECS_CLUSTER_NAME. Is the cluster set up?"
    exit 1
fi

# Get network config from existing service
EXISTING_SVC_NAME=$(echo "$EXISTING_SERVICE" | awk -F'/' '{print $NF}')
NETWORK_CONFIG=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$EXISTING_SVC_NAME" \
    --query 'services[0].networkConfiguration.awsvpcConfiguration' --output json --region "$AWS_REGION")

DISCOVERED_SUBNETS=$(echo "$NETWORK_CONFIG" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(d['subnets']))" 2>/dev/null || echo "")
DISCOVERED_SG=$(echo "$NETWORK_CONFIG" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(d['securityGroups']))" 2>/dev/null || echo "")

if [ -n "$DISCOVERED_SUBNETS" ]; then
    ok "Discovered subnets: $DISCOVERED_SUBNETS"
    ok "Discovered security group: $DISCOVERED_SG"
fi

PRIVATE_SUBNETS=$(prompt_with_default "Private Subnet IDs (comma-separated)" "$DISCOVERED_SUBNETS")
ECS_SG_ID=$(prompt_with_default "Security Group ID" "$DISCOVERED_SG")

# Get VPC ID from subnet
FIRST_SUBNET=$(echo "$PRIVATE_SUBNETS" | cut -d',' -f1)
VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$FIRST_SUBNET" \
    --query 'Subnets[0].VpcId' --output text --region "$AWS_REGION")
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].CidrBlock' --output text --region "$AWS_REGION")

# Bastion configuration
PROJECT_NAME="cdx-jit-k8s"
BASTION_SERVICE_NAME="${PROJECT_NAME}-bastion"
BASTION_TASK_FAMILY="${PROJECT_NAME}-bastion"
LOG_GROUP_NAME="/ecs/${PROJECT_NAME}/bastion"
BASTION_IMAGE=$(prompt_with_default "Bastion container image" "public.ecr.aws/amazonlinux/amazonlinux:2023")

echo ""
echo "━━━ Configuration Summary ━━━"
echo ""
echo "  Account          : $ACCOUNT_ID"
echo "  Region           : $AWS_REGION"
echo "  ECS Cluster      : $ECS_CLUSTER_NAME"
echo "  VPC              : $VPC_ID ($VPC_CIDR)"
echo "  Private Subnets  : $PRIVATE_SUBNETS"
echo "  Security Group   : $ECS_SG_ID"
echo "  IAM Role         : $BASTION_ROLE_NAME (new, dedicated)"
echo "  Service Name     : $BASTION_SERVICE_NAME"
echo "  Image            : $BASTION_IMAGE"
echo ""
read -p "Continue? (y/n) [y]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ============================================================================
# CLOUDWATCH LOG GROUP
# ============================================================================

step "CloudWatch Log Group"

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" \
    --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'].logGroupName" \
    --output text --region "$AWS_REGION" | grep -q "$LOG_GROUP_NAME"; then
    ok "Log group exists: $LOG_GROUP_NAME"
else
    aws logs create-log-group --log-group-name "$LOG_GROUP_NAME" --region "$AWS_REGION"
    aws logs put-retention-policy --log-group-name "$LOG_GROUP_NAME" \
        --retention-in-days 30 --region "$AWS_REGION"
    aws logs tag-log-group --log-group-name "$LOG_GROUP_NAME" \
        --tags '{"Purpose":"cdx-jit-k8s","created_by":"cloudanix","service":"bastion"}' 2>/dev/null || true
    ok "Log group created: $LOG_GROUP_NAME"
fi

# ============================================================================
# IAM — Create dedicated role for bastion ECS task
# ============================================================================

step "IAM Role ($BASTION_ROLE_NAME)"

ROLE_ARN=$(aws iam get-role --role-name "$BASTION_ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""

if [ -n "$ROLE_ARN" ]; then
    ok "Role already exists: $BASTION_ROLE_NAME ($ROLE_ARN)"
else
    cat > /tmp/ecs-trust.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ecs-tasks.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}
EOF

    aws iam create-role \
        --role-name "$BASTION_ROLE_NAME" \
        --assume-role-policy-document file:///tmp/ecs-trust.json \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" "Key=service,Value=bastion" > /dev/null

    ROLE_ARN=$(aws iam get-role --role-name "$BASTION_ROLE_NAME" \
        --query 'Role.Arn' --output text)
    ok "Role created: $BASTION_ROLE_NAME ($ROLE_ARN)"
fi

# Attach managed policies
aws iam attach-role-policy \
    --role-name "$BASTION_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true

aws iam attach-role-policy \
    --role-name "$BASTION_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

ok "Managed policies attached (ECSTaskExecution + SSM)"

# Inline policy for ECS Exec + EKS access + CloudWatch
cat > /tmp/bastion-inline-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ECSExecSSM",
            "Effect": "Allow",
            "Action": [
                "ssmmessages:CreateControlChannel",
                "ssmmessages:CreateDataChannel",
                "ssmmessages:OpenControlChannel",
                "ssmmessages:OpenDataChannel"
            ],
            "Resource": "*"
        },
        {
            "Sid": "EKSDescribe",
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster",
                "eks:ListClusters",
                "eks:DescribeNodegroup",
                "eks:ListNodegroups"
            ],
            "Resource": "*"
        },
        {
            "Sid": "CloudWatchLogs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:CreateLogGroup"
            ],
            "Resource": "*"
        }
    ]
}
EOF

aws iam put-role-policy \
    --role-name "$BASTION_ROLE_NAME" \
    --policy-name "${PROJECT_NAME}-bastion-inline-policy" \
    --policy-document file:///tmp/bastion-inline-policy.json
ok "Inline policy attached: ${PROJECT_NAME}-bastion-inline-policy"

info "Waiting 10s for IAM propagation..."
sleep 10

# ============================================================================
# SECURITY GROUP — Add HTTPS (443) ingress from VPC for ECS Exec/SSM
# ============================================================================

step "Security Group Rules"

# Check if 443 rule already exists
EXISTING_443=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$ECS_SG_ID" \
    --query "SecurityGroupRules[?FromPort==\`443\` && ToPort==\`443\` && CidrIpv4=='$VPC_CIDR'].SecurityGroupRuleId" \
    --output text --region "$AWS_REGION" 2>/dev/null)

if [ -n "$EXISTING_443" ] && [ "$EXISTING_443" != "None" ]; then
    ok "HTTPS (443) ingress from VPC already exists"
else
    aws ec2 authorize-security-group-ingress \
        --group-id "$ECS_SG_ID" \
        --protocol tcp --port 443 \
        --cidr "$VPC_CIDR" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true
    ok "Added HTTPS (443) ingress from $VPC_CIDR"
fi

# ============================================================================
# TASK DEFINITION
# ============================================================================

step "Task Definition"

CURRENT_IMAGE=$(aws ecs describe-task-definition --task-definition "$BASTION_TASK_FAMILY" \
    --query 'taskDefinition.containerDefinitions[0].image' --output text \
    --region "$AWS_REGION" 2>/dev/null) || CURRENT_IMAGE=""

if [ "$CURRENT_IMAGE" = "$BASTION_IMAGE" ]; then
    ok "Task definition up to date: $BASTION_TASK_FAMILY (image unchanged)"
else
    cat > /tmp/td-bastion.json << EOF
{
    "family": "${BASTION_TASK_FAMILY}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "executionRoleArn": "${ROLE_ARN}",
    "taskRoleArn": "${ROLE_ARN}",
    "containerDefinitions": [{
        "name": "bastion",
        "image": "${BASTION_IMAGE}",
        "essential": true,
        "command": ["sleep", "infinity"],
        "linuxParameters": {"initProcessEnabled": true},
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "${LOG_GROUP_NAME}",
                "awslogs-region": "${AWS_REGION}",
                "awslogs-stream-prefix": "bastion"
            }
        }
    }],
    "tags": [
        {"key": "owner", "value": "cloudanix"},
        {"key": "purpose", "value": "cdx-jit-k8s"},
        {"key": "service", "value": "bastion"},
        {"key": "scope", "value": "hub"},
        {"key": "created_by", "value": "cloudanix"}
    ]
}
EOF

    aws ecs register-task-definition \
        --cli-input-json file:///tmp/td-bastion.json \
        --region "$AWS_REGION" > /dev/null
    ok "Task definition registered: $BASTION_TASK_FAMILY (new revision)"
fi

# ============================================================================
# ECS SERVICE
# ============================================================================

step "ECS Service"

# Format subnets for network config
SUBNET_LIST=$(echo "$PRIVATE_SUBNETS" | tr ',' ',')

# Check if service already exists
EXISTING_SVC=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$BASTION_SERVICE_NAME" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [ -n "$EXISTING_SVC" ] && [ "$EXISTING_SVC" != "None" ]; then
    ok "Service already exists: $BASTION_SERVICE_NAME"
    info "Forcing new deployment..."
    aws ecs update-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service "$BASTION_SERVICE_NAME" \
        --task-definition "$BASTION_TASK_FAMILY" \
        --force-new-deployment \
        --region "$AWS_REGION" > /dev/null
    ok "Service updated with latest task definition"
else
    aws ecs create-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service-name "$BASTION_SERVICE_NAME" \
        --task-definition "$BASTION_TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --enable-execute-command \
        --propagate-tags SERVICE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_LIST],securityGroups=[$ECS_SG_ID],assignPublicIp=DISABLED}" \
        --tags "key=owner,value=cloudanix" "key=purpose,value=cdx-jit-k8s" "key=service,value=bastion" "key=scope,value=hub" "key=created_by,value=cloudanix" \
        --region "$AWS_REGION" > /dev/null
    ok "Service created: $BASTION_SERVICE_NAME"
fi

# ============================================================================
# WAIT FOR SERVICE
# ============================================================================

step "Waiting for service to stabilize"

info "This may take 1-2 minutes..."
if aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" \
    --services "$BASTION_SERVICE_NAME" --region "$AWS_REGION" 2>/dev/null; then
    ok "Service is stable"
else
    info "Service did not stabilize within timeout — check ECS console for task status"
fi

# ============================================================================
# VERIFY ECS EXEC
# ============================================================================

step "Verify ECS Exec"

TASK_ARN=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" \
    --service-name "$BASTION_SERVICE_NAME" \
    --desired-status RUNNING \
    --query 'taskArns[0]' --output text --region "$AWS_REGION" 2>/dev/null)

if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
    TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')
    ok "Running task: $TASK_ID"
    echo ""
    echo "  Connect with:"
    echo "    aws ecs execute-command \\"
    echo "      --cluster $ECS_CLUSTER_NAME \\"
    echo "      --task $TASK_ID \\"
    echo "      --container bastion \\"
    echo "      --interactive \\"
    echo "      --command \"/bin/bash\" \\"
    echo "      --region $AWS_REGION"
else
    info "No running task yet — wait a moment and check:"
    echo "    aws ecs list-tasks --cluster $ECS_CLUSTER_NAME --service-name $BASTION_SERVICE_NAME --region $AWS_REGION"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ EKS JIT Bastion (ECS) Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Account          : $ACCOUNT_ID"
echo "  Region           : $AWS_REGION"
echo "  Cluster          : $ECS_CLUSTER_NAME"
echo "  Service          : $BASTION_SERVICE_NAME"
echo "  Task Definition  : $BASTION_TASK_FAMILY"
echo "  IAM Role         : $BASTION_ROLE_NAME"
echo "  Log Group        : $LOG_GROUP_NAME"
echo "  VPC              : $VPC_ID"
echo "  Subnets          : $PRIVATE_SUBNETS"
echo "  Security Group   : $ECS_SG_ID"
echo ""
echo "  Tags: owner=cloudanix purpose=cdx-jit-k8s service=bastion scope=hub"
echo ""
echo "  Access (ECS Exec):"
echo "    TASK_ID=\$(aws ecs list-tasks --cluster $ECS_CLUSTER_NAME \\"
echo "      --service-name $BASTION_SERVICE_NAME --desired-status RUNNING \\"
echo "      --query 'taskArns[0]' --output text --region $AWS_REGION)"
echo ""
echo "    aws ecs execute-command --cluster $ECS_CLUSTER_NAME \\"
echo "      --task \$TASK_ID --container bastion --interactive \\"
echo "      --command \"/bin/bash\" --region $AWS_REGION"
echo ""
echo "  IAM Policy for end-users (attach to their role/user):"
echo "    - ecs:ExecuteCommand (condition: tags owner=cloudanix, service=bastion, purpose=cdx-jit-k8s)"
echo "    - ecs:DescribeTasks, ecs:ListTasks, ecs:DescribeClusters, ecs:ListServices"
echo "    - eks:Describe*"
echo "    - tag:GetResources"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
