#!/usr/bin/env bash
###############################################################################
# EKS JIT Bastion Hub — NEW VPC + ECS Cluster + Bastion Service
#
# Creates everything from scratch (idempotent — safe to re-run):
#   1. VPC with 2 public + 2 private subnets across 2 AZs
#   2. Internet Gateway + NAT Gateway
#   3. Route tables (public → IGW, private → NAT)
#   4. Security group for ECS tasks
#   5. Dedicated IAM role (cdx-jit-k8s-bastion-ECSRole)
#   6. CloudWatch Log Group
#   7. ECS Cluster (Fargate)
#   8. Task definition + ECS Service with ECS Exec enabled
#
# Tags all resources: owner=cloudanix purpose=cdx-jit-k8s service=bastion scope=hub
###############################################################################
set -euo pipefail

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
ok()   { echo "[✓] $*"; }
info() { echo "[i] $*"; }
step() { echo ""; echo "━━━ $* ━━━"; }

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -rp "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

TAGS="Key=owner,Value=cloudanix},{Key=purpose,Value=cdx-jit-k8s},{Key=service,Value=bastion},{Key=scope,Value=hub"

###############################################################################
# CONFIGURATION
###############################################################################
echo "=== EKS JIT Bastion Hub — Full Setup (New VPC + ECS Cluster) ==="
echo ""

read -rp "AWS Region [us-east-1]: " INPUT_REGION
REGION="${INPUT_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
info "Account: $ACCOUNT_ID | Region: $REGION"

read -rp "VPC CIDR block [10.200.0.0/16]: " INPUT_VPC_CIDR
VPC_CIDR="${INPUT_VPC_CIDR:-10.200.0.0/16}"

VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PUB_SUB_1_CIDR="${VPC_BASE}.1.0/24"
PUB_SUB_2_CIDR="${VPC_BASE}.2.0/24"
PRIV_SUB_1_CIDR="${VPC_BASE}.3.0/24"
PRIV_SUB_2_CIDR="${VPC_BASE}.4.0/24"

# Resolve AZs
AZ_1=$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[1].ZoneName" --output text)

# Fixed names
PROJECT="cdx-jit-k8s-hub"
VPC_NAME="${PROJECT}-vpc"
CLUSTER_NAME="${PROJECT}-cluster"
BASTION_ROLE_NAME="cdx-jit-k8s-bastion-ECSRole"
LOG_GROUP="/ecs/cdx-jit-k8s/bastion"
BASTION_TASK_FAMILY="cdx-jit-k8s-bastion"
BASTION_SERVICE_NAME="cdx-jit-k8s-bastion"

read -rp "Bastion container image [public.ecr.aws/amazonlinux/amazonlinux:2023]: " INPUT_IMAGE
BASTION_IMAGE="${INPUT_IMAGE:-public.ecr.aws/amazonlinux/amazonlinux:2023}"

echo ""
echo "=== Configuration ==="
echo "  VPC CIDR       : $VPC_CIDR"
echo "  Public Subnets : $PUB_SUB_1_CIDR ($AZ_1), $PUB_SUB_2_CIDR ($AZ_2)"
echo "  Private Subnets: $PRIV_SUB_1_CIDR ($AZ_1), $PRIV_SUB_2_CIDR ($AZ_2)"
echo "  Cluster        : $CLUSTER_NAME"
echo "  IAM Role       : $BASTION_ROLE_NAME"
echo "  Image          : $BASTION_IMAGE"
echo ""
###############################################################################
# VPC
###############################################################################
step "VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" "Name=cidr,Values=$VPC_CIDR" \
    --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{$TAGS}]" \
        --query 'Vpc.VpcId' --output text --region "$REGION")
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$REGION"
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi

###############################################################################
# Internet Gateway
###############################################################################
step "Internet Gateway"
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null)

if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw},{$TAGS}]" \
        --query 'InternetGateway.InternetGatewayId' --output text --region "$REGION")
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
    ok "IGW created: $IGW_ID"
else
    ok "IGW exists: $IGW_ID"
fi

###############################################################################
# Subnets
###############################################################################
step "Subnets"

find_or_create_subnet() {
    local vpc_id=$1 cidr=$2 az=$3 name=$4
    local sub_id
    sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text --region "$REGION" 2>/dev/null)
    if [[ -z "$sub_id" || "$sub_id" == "None" ]]; then
        sub_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name},{$TAGS}]" \
            --query 'Subnet.SubnetId' --output text --region "$REGION")
        echo "[✓] Subnet created: $name ($sub_id)" >&2
    else
        echo "[✓] Subnet exists: $name ($sub_id)" >&2
    fi
    echo "$sub_id"
}

PUB_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PUB_SUB_1_CIDR" "$AZ_1" "${PROJECT}-public-1")
PUB_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PUB_SUB_2_CIDR" "$AZ_2" "${PROJECT}-public-2")
PRIV_SUB_1=$(find_or_create_subnet "$VPC_ID" "$PRIV_SUB_1_CIDR" "$AZ_1" "${PROJECT}-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$VPC_ID" "$PRIV_SUB_2_CIDR" "$AZ_2" "${PROJECT}-private-2")

###############################################################################
# NAT Gateway
###############################################################################
step "NAT Gateway"
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Name,Values=${PROJECT}-natgw" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text --region "$REGION" 2>/dev/null)

if [[ -z "$NAT_GW_ID" || "$NAT_GW_ID" == "None" ]]; then
    # Check if EIP already exists (from a previous partial run)
    EIP_ALLOC=$(aws ec2 describe-addresses \
        --filters "Name=tag:Name,Values=${PROJECT}-eip" \
        --query 'Addresses[?AssociationId==null].AllocationId | [0]' \
        --output text --region "$REGION" 2>/dev/null)
    if [[ -z "$EIP_ALLOC" || "$EIP_ALLOC" == "None" ]]; then
        EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
            --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip},{$TAGS}]" \
            --query 'AllocationId' --output text --region "$REGION")
    fi
    NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP_ALLOC" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-natgw},{$TAGS}]" \
        --query 'NatGateway.NatGatewayId' --output text --region "$REGION")
    info "Waiting for NAT Gateway..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" --region "$REGION"
    ok "NAT Gateway created: $NAT_GW_ID"
else
    ok "NAT Gateway exists: $NAT_GW_ID"
fi

###############################################################################
# Route Tables
###############################################################################
step "Route Tables"

# Public RT
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT}-pub-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$REGION" 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-pub-rt},{$TAGS}]" \
        --query 'RouteTable.RouteTableId' --output text --region "$REGION")
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$IGW_ID" --region "$REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_1" --region "$REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_2" --region "$REGION" > /dev/null
fi
ok "Public RT: $PUB_RT"

# Private RT
PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT}-priv-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$REGION" 2>/dev/null)
if [[ -z "$PRIV_RT" || "$PRIV_RT" == "None" ]]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-priv-rt},{$TAGS}]" \
        --query 'RouteTable.RouteTableId' --output text --region "$REGION")
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$NAT_GW_ID" --region "$REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_1" --region "$REGION" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_2" --region "$REGION" > /dev/null
fi
ok "Private RT: $PRIV_RT"

###############################################################################
# Security Group
###############################################################################
step "Security Group"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PROJECT}-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group --group-name "${PROJECT}-sg" \
        --description "EKS JIT bastion - ECS Exec (443 from VPC)" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-sg},{$TAGS}]" \
        --query 'GroupId' --output text --region "$REGION")
    # HTTPS ingress from VPC (for SSM/ECS Exec via VPC endpoints or NAT)
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 443 --cidr "$VPC_CIDR" --region "$REGION" > /dev/null
    ok "Security Group created: $SG_ID"
else
    ok "Security Group exists: $SG_ID"
fi

###############################################################################
# IAM Role (dedicated for bastion)
###############################################################################
step "IAM Role ($BASTION_ROLE_NAME)"

ROLE_ARN=$(aws iam get-role --role-name "$BASTION_ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""

if [[ -n "$ROLE_ARN" ]]; then
    ok "Role exists: $BASTION_ROLE_NAME ($ROLE_ARN)"
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
    aws iam create-role --role-name "$BASTION_ROLE_NAME" \
        --assume-role-policy-document file:///tmp/ecs-trust.json \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" "Key=service,Value=bastion" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$BASTION_ROLE_NAME" --query 'Role.Arn' --output text)
    ok "Role created: $BASTION_ROLE_NAME ($ROLE_ARN)"
fi

# Managed policies
aws iam attach-role-policy --role-name "$BASTION_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true
aws iam attach-role-policy --role-name "$BASTION_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
ok "Managed policies attached"

# Inline policy
cat > /tmp/bastion-inline.json << 'EOF'
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
aws iam put-role-policy --role-name "$BASTION_ROLE_NAME" \
    --policy-name "cdx-jit-k8s-bastion-inline-policy" \
    --policy-document file:///tmp/bastion-inline.json
ok "Inline policy attached"

info "Waiting 10s for IAM propagation..."
sleep 10

###############################################################################
# CloudWatch Log Group
###############################################################################
step "CloudWatch Log Group"

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" \
    --output text --region "$REGION" | grep -q "$LOG_GROUP"; then
    ok "Log group exists: $LOG_GROUP"
else
    aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
    aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30 --region "$REGION"
    ok "Log group created: $LOG_GROUP"
fi

###############################################################################
# ECS Cluster
###############################################################################
step "ECS Cluster"

# Ensure ECS Service Linked Role exists
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
    --query 'clusters[0].status' --output text --region "$REGION" 2>/dev/null)

if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
    ok "Cluster exists: $CLUSTER_NAME"
else
    CLUSTER_CREATED=false
    for attempt in 1 2 3; do
        if aws ecs create-cluster --cluster-name "$CLUSTER_NAME" \
            --capacity-providers FARGATE \
            --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
            --configuration "executeCommandConfiguration={logging=DEFAULT}" \
            --tags "key=owner,value=cloudanix" "key=purpose,value=cdx-jit-k8s" "key=service,value=bastion" "key=scope,value=hub" \
            --region "$REGION" > /dev/null 2>&1; then
            CLUSTER_CREATED=true
            break
        fi
        info "ECS SLR not ready, retrying in 15s (attempt $attempt/3)..."
        sleep 15
    done
    if [[ "$CLUSTER_CREATED" == false ]]; then
        echo "[ERROR] Failed to create ECS cluster. Try again in a minute."
        exit 1
    fi
    ok "Cluster created: $CLUSTER_NAME"
fi

###############################################################################
# Task Definition (only registers if image changed)
###############################################################################
step "Task Definition"

CURRENT_IMAGE=$(aws ecs describe-task-definition --task-definition "$BASTION_TASK_FAMILY" \
    --query 'taskDefinition.containerDefinitions[0].image' --output text \
    --region "$REGION" 2>/dev/null) || CURRENT_IMAGE=""

if [[ "$CURRENT_IMAGE" == "$BASTION_IMAGE" ]]; then
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
                "awslogs-group": "${LOG_GROUP}",
                "awslogs-region": "${REGION}",
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

    aws ecs register-task-definition --cli-input-json file:///tmp/td-bastion.json --region "$REGION" > /dev/null
    ok "Task definition registered: $BASTION_TASK_FAMILY (new revision)"
fi

###############################################################################
# ECS Service
###############################################################################
step "ECS Service"

EXISTING_SVC=$(aws ecs describe-services --cluster "$CLUSTER_NAME" \
    --services "$BASTION_SERVICE_NAME" \
    --query 'services[?status==`ACTIVE`].serviceName' --output text \
    --region "$REGION" 2>/dev/null)

if [[ -n "$EXISTING_SVC" && "$EXISTING_SVC" != "None" ]]; then
    ok "Service exists: $BASTION_SERVICE_NAME — forcing new deployment"
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$BASTION_SERVICE_NAME" \
        --task-definition "$BASTION_TASK_FAMILY" --force-new-deployment \
        --region "$REGION" > /dev/nullfi
else
    aws ecs create-service \
        --cluster "$CLUSTER_NAME" \
        --service-name "$BASTION_SERVICE_NAME" \
        --task-definition "$BASTION_TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --enable-execute-command \
        --propagate-tags SERVICE \
        --network-configuration "awsvpcConfiguration={subnets=[$PRIV_SUB_1,$PRIV_SUB_2],securityGroups=[$SG_ID],assignPublicIp=DISABLED}" \
        --tags "key=owner,value=cloudanix" "key=purpose,value=cdx-jit-k8s" "key=service,value=bastion" "key=scope,value=hub" "key=created_by,value=cloudanix" \
        --region "$REGION" > /dev/null
    ok "Service created: $BASTION_SERVICE_NAME"
fi

###############################################################################
# Wait + Verify
###############################################################################
step "Waiting for service to stabilize"
info "This may take 1-2 minutes..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$BASTION_SERVICE_NAME" --region "$REGION" 2>/dev/null && \
    ok "Service is stable" || info "Timeout — check ECS console"

TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER_NAME" \
    --service-name "$BASTION_SERVICE_NAME" --desired-status RUNNING \
    --query 'taskArns[0]' --output text --region "$REGION" 2>/dev/null)

###############################################################################
# Summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ EKS JIT Bastion Hub — Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  VPC              : $VPC_ID ($VPC_CIDR)"
echo "  Public Subnets   : $PUB_SUB_1 ($AZ_1), $PUB_SUB_2 ($AZ_2)"
echo "  Private Subnets  : $PRIV_SUB_1 ($AZ_1), $PRIV_SUB_2 ($AZ_2)"
echo "  NAT Gateway      : $NAT_GW_ID"
echo "  Security Group   : $SG_ID"
echo "  ECS Cluster      : $CLUSTER_NAME"
echo "  Service          : $BASTION_SERVICE_NAME"
echo "  Task Definition  : $BASTION_TASK_FAMILY"
echo "  IAM Role         : $BASTION_ROLE_NAME ($ROLE_ARN)"
echo "  Log Group        : $LOG_GROUP"
echo "  Region           : $REGION"
echo ""
echo "  Tags: owner=cloudanix purpose=cdx-jit-k8s service=bastion scope=hub"
echo ""
if [[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]]; then
    TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')
    echo "  Connect via ECS Exec:"
    echo "    aws ecs execute-command --cluster $CLUSTER_NAME \\"
    echo "      --task $TASK_ID --container bastion --interactive \\"
    echo "      --command \"/bin/bash\" --region $REGION"
else
    echo "  Connect (after task starts):"
    echo "    TASK_ID=\$(aws ecs list-tasks --cluster $CLUSTER_NAME \\"
    echo "      --service-name $BASTION_SERVICE_NAME --desired-status RUNNING \\"
    echo "      --query 'taskArns[0]' --output text --region $REGION)"
    echo ""
    echo "    aws ecs execute-command --cluster $CLUSTER_NAME \\"
    echo "      --task \$TASK_ID --container bastion --interactive \\"
    echo "      --command \"/bin/bash\" --region $REGION"
fi
echo ""
echo "  Next steps:"
echo "    → Run 3.setup-vpc-peering.sh to peer with EKS VPCs"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
