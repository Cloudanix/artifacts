#!/usr/bin/env bash
# =============================================================================
# Step: Setup Bastion Hub (New VPC) — ECS Fargate
# =============================================================================
# Creates the EKS bastion hub in a new VPC and runs the bastion as an ECS
# Fargate task (amazonlinux:2023, sleep infinity, ECS Exec enabled).
#
# Creates: VPC, subnets, IGW, NAT gateway, route tables, security group,
# ECS task role, CloudWatch log group, ECS cluster (new or reuse existing),
# task definition, and a 1-replica service with ECS Exec enabled.
#
# Required env vars:
#   AWS_REGION, VPC_CIDR, ECS_CLUSTER_NAME, ECS_CLUSTER_MODE
#     ECS_CLUSTER_MODE = "new" | "existing"
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:ECS_CLUSTER_NAME, OUTPUT:BASTION_SG_ID,
#   OUTPUT:BASTION_SERVICE_NAME, OUTPUT:BASTION_TASK_FAMILY,
#   OUTPUT:PRIVATE_SUBNET_1_ID, OUTPUT:PRIVATE_SUBNET_2_ID
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION VPC_CIDR ECS_CLUSTER_NAME ECS_CLUSTER_MODE

export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# =============================================================================
# CONFIGURATION
# =============================================================================

VPC_NAME="cdx-jit-k8s-hub-vpc"
SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-bastion-ECSRole"
LOG_GROUP="/ecs/cdx-jit-k8s/bastion"
TASK_FAMILY="cdx-jit-k8s-bastion"
SERVICE_NAME="cdx-jit-k8s-bastion"
BASTION_IMAGE="public.ecr.aws/amazonlinux/amazonlinux:2023"

# Standard tags (matches existing setups)
TAG_SPEC="{Key=owner,Value=cloudanix},{Key=purpose,Value=cdx-jit-k8s},{Key=created_by,Value=cloudanix},{Key=service,Value=bastion},{Key=scope,Value=hub}"

VPC_BASE=$(echo "$VPC_CIDR" | cut -d'.' -f1-2)
PUB_SUB_1_CIDR="${VPC_BASE}.1.0/24"
PUB_SUB_2_CIDR="${VPC_BASE}.2.0/24"
PRIV_SUB_1_CIDR="${VPC_BASE}.3.0/24"
PRIV_SUB_2_CIDR="${VPC_BASE}.4.0/24"

AZ_1=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
AZ_2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)

info "Account: $ACCOUNT_ID | Region: $AWS_REGION | VPC CIDR: $VPC_CIDR"
info "ECS cluster: $ECS_CLUSTER_NAME (mode: $ECS_CLUSTER_MODE)"

aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

# =============================================================================
# VPC
# =============================================================================

step "VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" "Name=cidr,Values=$VPC_CIDR" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null)
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},$TAG_SPEC]" \
        --query "Vpc.VpcId" --output text)
    ok "VPC created: $VPC_ID"
else
    ok "VPC exists: $VPC_ID"
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'

# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null)
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-igw},$TAG_SPEC]" \
        --query "InternetGateway.InternetGatewayId" --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi

# =============================================================================
# SUBNETS
# =============================================================================

step "Subnets"
find_or_create_subnet() {
    local cidr=$1 az=$2 name=$3
    local sub_id
    sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$sub_id" || "$sub_id" == "None" ]]; then
        sub_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name},$TAG_SPEC]" \
            --query 'Subnet.SubnetId' --output text)
    fi
    echo "$sub_id"
}

PUB_SUB_1=$(find_or_create_subnet "$PUB_SUB_1_CIDR" "$AZ_1" "cdx-jit-k8s-hub-public-1")
PUB_SUB_2=$(find_or_create_subnet "$PUB_SUB_2_CIDR" "$AZ_2" "cdx-jit-k8s-hub-public-2")
PRIV_SUB_1=$(find_or_create_subnet "$PRIV_SUB_1_CIDR" "$AZ_1" "cdx-jit-k8s-hub-private-1")
PRIV_SUB_2=$(find_or_create_subnet "$PRIV_SUB_2_CIDR" "$AZ_2" "cdx-jit-k8s-hub-private-2")
ok "Subnets: public=$PUB_SUB_1,$PUB_SUB_2 private=$PRIV_SUB_1,$PRIV_SUB_2"

# =============================================================================
# NAT GATEWAY + ROUTE TABLES
# =============================================================================

step "NAT Gateway"
NAT_GW_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query "NatGateways[0].NatGatewayId" --output text 2>/dev/null)
if [[ -z "$NAT_GW_ID" || "$NAT_GW_ID" == "None" ]]; then
    EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text)
    NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_SUB_1" --allocation-id "$EIP_ALLOC" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-natgw},$TAG_SPEC]" \
        --query "NatGateway.NatGatewayId" --output text)
    info "Waiting for NAT Gateway..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
    ok "NAT created: $NAT_GW_ID"
else
    ok "NAT exists: $NAT_GW_ID"
fi

step "Route Tables"
PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=cdx-jit-k8s-hub-public-rt" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)
if [[ -z "$PUB_RT" || "$PUB_RT" == "None" ]]; then
    PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-public-rt},$TAG_SPEC]" \
        --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_1" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_2" > /dev/null
fi

PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=cdx-jit-k8s-hub-private-rt" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)
if [[ -z "$PRIV_RT" || "$PRIV_RT" == "None" ]]; then
    PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cdx-jit-k8s-hub-private-rt},$TAG_SPEC]" \
        --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_1" > /dev/null
    aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_2" > /dev/null
fi
ok "Route tables configured"

# =============================================================================
# SECURITY GROUP
# =============================================================================

step "Security Group"
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
        --description "EKS JIT bastion SG - ECS Fargate, egress only (SSM/ECS Exec)" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},$TAG_SPEC]" \
        --query "GroupId" --output text)
    # Egress-only (Fargate reaches ECS/SSM/ECR via NAT); ingress not needed
    aws ec2 authorize-security-group-egress --group-id "$SG_ID" --protocol "-1" --cidr "0.0.0.0/0" 2>/dev/null || true
    ok "SG created: $SG_ID"
else
    ok "SG exists: $SG_ID"
fi

# =============================================================================
# ECS TASK ROLE
# =============================================================================

step "ECS Task Role"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null) || ROLE_ARN=""
if [[ -z "$ROLE_ARN" ]]; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --tags "Key=owner,Value=cloudanix" "Key=purpose,Value=cdx-jit-k8s" "Key=created_by,Value=cloudanix" "Key=service,Value=bastion" "Key=scope,Value=hub" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "Task role created: $ROLE_NAME"
else
    ok "Task role exists: $ROLE_NAME"
fi

# Execution role permissions (pull image, write logs) + SSM channel for ECS Exec
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

# Inline policy: SSM messages channel required for ECS Exec + EKS describe
cat > /tmp/bastion-exec-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ECSExecSSMChannel",
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
                "eks:ListClusters"
            ],
            "Resource": "*"
        }
    ]
}
EOF
aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name "cdx-jit-k8s-bastion-exec" \
    --policy-document file:///tmp/bastion-exec-policy.json
ok "ECS Exec + EKS policies attached"

info "Waiting for IAM propagation..."
sleep 10

# =============================================================================
# CLOUDWATCH LOG GROUP
# =============================================================================

step "CloudWatch Log Group"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
ok "Log group: $LOG_GROUP"

# =============================================================================
# ECS CLUSTER (new or reuse existing)
# =============================================================================

step "ECS Cluster"
CLUSTER_ARN=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER_NAME" \
    --query 'clusters[?status==`ACTIVE`].clusterArn | [0]' --output text 2>/dev/null)

if [[ -n "$CLUSTER_ARN" && "$CLUSTER_ARN" != "None" ]]; then
    ok "Using existing cluster: $ECS_CLUSTER_NAME"
elif [[ "$ECS_CLUSTER_MODE" == "existing" ]]; then
    error "ECS cluster '$ECS_CLUSTER_NAME' not found but mode is 'existing'."
    error "Create it first (via jit-db/jit-vm setup) or choose 'new'."
    exit 1
else
    CLUSTER_ARN=$(aws ecs create-cluster --cluster-name "$ECS_CLUSTER_NAME" \
        --capacity-providers FARGATE FARGATE_SPOT \
        --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
        --tags "key=owner,value=cloudanix" "key=purpose,value=cdx-jit-k8s" "key=created_by,value=cloudanix" \
        --query 'cluster.clusterArn' --output text)
    ok "Cluster created: $ECS_CLUSTER_NAME"
fi

# =============================================================================
# TASK DEFINITION
# =============================================================================

step "Task Definition"
TASK_DEF=$(jq -n \
    --arg family "$TASK_FAMILY" \
    --arg image "$BASTION_IMAGE" \
    --arg role "$ROLE_ARN" \
    --arg region "$AWS_REGION" \
    --arg lg "$LOG_GROUP" \
    '{
        family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
        cpu: "256", memory: "512", executionRoleArn: $role, taskRoleArn: $role,
        containerDefinitions: [{
            name: "bastion",
            image: $image,
            cpu: 0, essential: true,
            command: ["sleep", "infinity"],
            linuxParameters: {initProcessEnabled: true},
            logConfiguration: {logDriver: "awslogs", options: {"awslogs-group": $lg, "awslogs-region": $region, "awslogs-stream-prefix": "bastion"}}
        }],
        tags: [
            {key:"owner", value:"cloudanix"},
            {key:"purpose", value:"cdx-jit-k8s"},
            {key:"created_by", value:"cloudanix"},
            {key:"service", value:"bastion"},
            {key:"scope", value:"hub"}
        ]
    }')
echo "$TASK_DEF" > /tmp/bastion-task-def.json
aws ecs register-task-definition --cli-input-json file:///tmp/bastion-task-def.json > /dev/null
ok "Task definition registered: $TASK_FAMILY"

# =============================================================================
# ECS SERVICE (1 replica, ECS Exec enabled)
# =============================================================================

step "ECS Service"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$PRIV_SUB_1,$PRIV_SUB_2],securityGroups=[$SG_ID],assignPublicIp=DISABLED}"

EXISTING_SVC=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text 2>/dev/null)
if [[ -n "$EXISTING_SVC" && "$EXISTING_SVC" != "None" ]]; then
    aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
        --task-definition "$TASK_FAMILY" --enable-execute-command \
        --force-new-deployment > /dev/null
    ok "Service updated: $SERVICE_NAME"
else
    aws ecs create-service --cluster "$ECS_CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --task-definition "$TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --enable-execute-command \
        --network-configuration "$NETWORK_CONFIG" \
        --tags "key=owner,value=cloudanix" "key=purpose,value=cdx-jit-k8s" "key=created_by,value=cloudanix" "key=service,value=bastion" "key=scope,value=hub" > /dev/null
    ok "Service created: $SERVICE_NAME"
fi

info "Waiting for bastion service to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" 2>/dev/null || true

# =============================================================================
# OUTPUT
# =============================================================================

ok "Bastion hub setup complete (ECS Fargate)"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:VPC_CIDR=${VPC_CIDR}"
echo "OUTPUT:ECS_CLUSTER_NAME=${ECS_CLUSTER_NAME}"
echo "OUTPUT:BASTION_SG_ID=${SG_ID}"
echo "OUTPUT:BASTION_SERVICE_NAME=${SERVICE_NAME}"
echo "OUTPUT:BASTION_TASK_FAMILY=${TASK_FAMILY}"
echo "OUTPUT:PRIVATE_SUBNET_1_ID=${PRIV_SUB_1}"
echo "OUTPUT:PRIVATE_SUBNET_2_ID=${PRIV_SUB_2}"
