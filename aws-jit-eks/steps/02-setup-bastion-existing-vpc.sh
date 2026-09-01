#!/usr/bin/env bash
# =============================================================================
# Step: Setup Bastion (Existing VPC) — ECS Fargate
# =============================================================================
# Runs the EKS bastion as an ECS Fargate task in a user-provided VPC/subnet.
# Does NOT create VPC/subnets/NAT — expects the private subnet to already have
# outbound connectivity (NAT gateway or VPC endpoints for ECS/SSM/ECR).
#
# Creates: security group, ECS task role, CloudWatch log group, ECS cluster
# (new or reuse existing), task definition, and a 1-replica service with
# ECS Exec enabled.
#
# Required env vars:
#   AWS_REGION, ECS_CLUSTER_NAME, ECS_CLUSTER_MODE, VPC_ID, PRIV_SUB_1
#     ECS_CLUSTER_MODE = "new" | "existing"
#
# Outputs:
#   OUTPUT:VPC_ID, OUTPUT:ECS_CLUSTER_NAME, OUTPUT:BASTION_SG_ID,
#   OUTPUT:BASTION_SERVICE_NAME, OUTPUT:BASTION_TASK_FAMILY
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_env AWS_REGION ECS_CLUSTER_NAME ECS_CLUSTER_MODE VPC_ID PRIV_SUB_1

export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# =============================================================================
# CONFIGURATION
# =============================================================================

SG_NAME="cdx-jit-k8s-hub-bastion-sg"
ROLE_NAME="cdx-jit-k8s-bastion-ECSRole"
LOG_GROUP="/ecs/cdx-jit-k8s/bastion"
TASK_FAMILY="cdx-jit-k8s-bastion"
SERVICE_NAME="cdx-jit-k8s-bastion"
BASTION_IMAGE="public.ecr.aws/amazonlinux/amazonlinux:2023"

TAG_SPEC="{Key=Environment,Value=Prod},{Key=Created_by,Value=Cloudanix},{Key=purpose,Value=jit_k8s},{Key=aws-apn-id,Value=${CDX_APN_ID}},{Key=service,Value=bastion},{Key=scope,Value=hub}"

info "Account: $ACCOUNT_ID | Region: $AWS_REGION"
info "ECS cluster: $ECS_CLUSTER_NAME (mode: $ECS_CLUSTER_MODE)"

aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

# =============================================================================
# VALIDATE VPC + SUBNET
# =============================================================================

step "Validate Network"
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --query "Vpcs[0].CidrBlock" --output text 2>/dev/null)
if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
    error "VPC $VPC_ID not found in region $AWS_REGION"; exit 1
fi

SUBNET_VPC=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SUB_1" \
    --query "Subnets[0].VpcId" --output text 2>/dev/null)
if [[ "$SUBNET_VPC" != "$VPC_ID" ]]; then
    error "Subnet $PRIV_SUB_1 does not belong to VPC $VPC_ID (belongs to $SUBNET_VPC)"; exit 1
fi

# Second subnet is optional; ECS service can run with a single subnet
SUBNETS="$PRIV_SUB_1"
if [[ -n "${PRIV_SUB_2:-}" ]]; then
    SUB2_VPC=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SUB_2" \
        --query "Subnets[0].VpcId" --output text 2>/dev/null)
    if [[ "$SUB2_VPC" == "$VPC_ID" ]]; then
        SUBNETS="$PRIV_SUB_1,$PRIV_SUB_2"
    fi
fi
ok "VPC: $VPC_ID ($VPC_CIDR) | Subnets: $SUBNETS"

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
        --tags "Key=Environment,Value=Prod" "Key=Created_by,Value=Cloudanix" "Key=purpose,Value=jit_k8s" "Key=aws-apn-id,Value=${CDX_APN_ID}" "Key=service,Value=bastion" "Key=scope,Value=hub" > /dev/null
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    ok "Task role created: $ROLE_NAME"
else
    ok "Task role exists: $ROLE_NAME"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

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
        --tags "key=Environment,value=Prod" "key=Created_by,value=Cloudanix" "key=purpose,value=jit_k8s" "key=aws-apn-id,value=${CDX_APN_ID}" \
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
    --arg apn "$CDX_APN_ID" \
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
            {key:"Environment", value:"Prod"},
            {key:"Created_by", value:"Cloudanix"},
            {key:"purpose", value:"jit_k8s"},
            {key:"aws-apn-id", value:$apn},
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
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_ID],assignPublicIp=DISABLED}"

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
        --tags "key=Environment,value=Prod" "key=Created_by,value=Cloudanix" "key=purpose,value=jit_k8s" "key=aws-apn-id,value=${CDX_APN_ID}" "key=service,value=bastion" "key=scope,value=hub" > /dev/null
    ok "Service created: $SERVICE_NAME"
fi

info "Waiting for bastion service to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" 2>/dev/null || true

# =============================================================================
# OUTPUT
# =============================================================================

ok "Bastion setup complete (ECS Fargate, existing VPC)"
echo "OUTPUT:VPC_ID=${VPC_ID}"
echo "OUTPUT:VPC_CIDR=${VPC_CIDR}"
echo "OUTPUT:ECS_CLUSTER_NAME=${ECS_CLUSTER_NAME}"
echo "OUTPUT:BASTION_SG_ID=${SG_ID}"
echo "OUTPUT:BASTION_SERVICE_NAME=${SERVICE_NAME}"
echo "OUTPUT:BASTION_TASK_FAMILY=${TASK_FAMILY}"
