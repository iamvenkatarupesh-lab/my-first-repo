#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap.sh
# One-time setup: creates every AWS resource your GitHub Actions pipeline needs.
# Run this ONCE from your laptop with AWS CLI configured.
#
# Creates:
#   - ECR repository         (to store your Docker image)
#   - CloudWatch log group   (for container logs)
#   - IAM role               (so ECS can pull images and write logs)
#   - Security group         (allows HTTP port 80 from the internet)
#   - ECS cluster            (Fargate, the place your container runs)
#   - ECS service            (keeps 1 task running, assigns a public IP)
# -----------------------------------------------------------------------------
set -euo pipefail

# ---- EDIT THESE IF YOU WANT ----
AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAME="static-site"
# ---------------------------------

CLUSTER_NAME="${APP_NAME}-cluster"
SERVICE_NAME="${APP_NAME}-service"
TASK_FAMILY="${APP_NAME}-task"
ECR_REPO="${APP_NAME}"
LOG_GROUP="/ecs/${APP_NAME}"
SG_NAME="${APP_NAME}-sg"
EXEC_ROLE_NAME="${APP_NAME}-exec-role"

echo ">>> Using region: $AWS_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo ">>> Account: $ACCOUNT_ID"

# 1. ECR repo ------------------------------------------------------------------
echo ">>> Creating ECR repo: $ECR_REPO"
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION" >/dev/null

# 2. CloudWatch log group ------------------------------------------------------
echo ">>> Creating log group: $LOG_GROUP"
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$AWS_REGION" \
  --query "logGroups[?logGroupName=='$LOG_GROUP']" --output text | grep -q "$LOG_GROUP" \
  || aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION"

# 3. IAM execution role --------------------------------------------------------
echo ">>> Creating execution role: $EXEC_ROLE_NAME"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1 \
  || aws iam create-role --role-name "$EXEC_ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
EXEC_ROLE_ARN=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query 'Role.Arn' --output text)

# 4. Default VPC + subnets + security group ------------------------------------
echo ">>> Finding default VPC + subnets"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
SUBNET_IDS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[].SubnetId' --output text --region "$AWS_REGION" | tr '\t' ',')
echo "    VPC: $VPC_ID"
echo "    Subnets: $SUBNET_IDS"

echo ">>> Creating security group: $SG_NAME"
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "HTTP 80 for $APP_NAME" \
    --vpc-id "$VPC_ID" --region "$AWS_REGION" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region "$AWS_REGION"
fi
echo "    SG: $SG_ID"

# 5. ECS cluster ---------------------------------------------------------------
echo ">>> Creating ECS cluster: $CLUSTER_NAME"
aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

# 6. First task definition (placeholder nginx image until first real deploy) ---
echo ">>> Registering initial task definition"
PLACEHOLDER_IMAGE="public.ecr.aws/nginx/nginx:alpine"
cat > /tmp/td.json <<EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "containerDefinitions": [{
    "name": "web",
    "image": "$PLACEHOLDER_IMAGE",
    "essential": true,
    "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "$LOG_GROUP",
        "awslogs-region": "$AWS_REGION",
        "awslogs-stream-prefix": "web"
      }
    }
  }]
}
EOF
aws ecs register-task-definition --cli-input-json file:///tmp/td.json --region "$AWS_REGION" >/dev/null

# 7. ECS service ---------------------------------------------------------------
echo ">>> Creating ECS service: $SERVICE_NAME"
aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --region "$AWS_REGION" >/dev/null 2>&1 || echo "    (service already exists, skipping)"

echo ""
echo "============================================================"
echo " BOOTSTRAP COMPLETE"
echo "============================================================"
echo " Put these as GitHub Actions secrets (Settings > Secrets):"
echo "   AWS_REGION           = $AWS_REGION"
echo "   AWS_ACCOUNT_ID       = $ACCOUNT_ID"
echo "   ECR_REPOSITORY       = $ECR_REPO"
echo "   ECS_CLUSTER          = $CLUSTER_NAME"
echo "   ECS_SERVICE          = $SERVICE_NAME"
echo "   ECS_TASK_FAMILY      = $TASK_FAMILY"
echo "   EXECUTION_ROLE_ARN   = $EXEC_ROLE_ARN"
echo ""
echo " Plus the IAM user access keys you created (see README):"
echo "   AWS_ACCESS_KEY_ID"
echo "   AWS_SECRET_ACCESS_KEY"
echo "============================================================"
