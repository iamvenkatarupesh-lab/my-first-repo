#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# teardown.sh
# DELETES every AWS resource bootstrap.sh created, so you stop being billed.
# Safe to run multiple times.
# -----------------------------------------------------------------------------
set -uo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAME="static-site"

CLUSTER_NAME="${APP_NAME}-cluster"
SERVICE_NAME="${APP_NAME}-service"
TASK_FAMILY="${APP_NAME}-task"
ECR_REPO="${APP_NAME}"
LOG_GROUP="/ecs/${APP_NAME}"
SG_NAME="${APP_NAME}-sg"
EXEC_ROLE_NAME="${APP_NAME}-exec-role"

echo ">>> Region: $AWS_REGION"

echo ">>> Scaling service to 0 and deleting it"
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
  --desired-count 0 --region "$AWS_REGION" >/dev/null 2>&1 || true
aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
  --force --region "$AWS_REGION" >/dev/null 2>&1 || true

echo ">>> Deregistering task definitions for $TASK_FAMILY"
for arn in $(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" \
    --region "$AWS_REGION" --query 'taskDefinitionArns[]' --output text 2>/dev/null); do
  aws ecs deregister-task-definition --task-definition "$arn" --region "$AWS_REGION" >/dev/null 2>&1 || true
done

echo ">>> Deleting ECS cluster"
aws ecs delete-cluster --cluster "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true

echo ">>> Deleting ECR repo (force = delete images too)"
aws ecr delete-repository --repository-name "$ECR_REPO" --force \
  --region "$AWS_REGION" >/dev/null 2>&1 || true

echo ">>> Deleting log group"
aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" >/dev/null 2>&1 || true

echo ">>> Deleting security group"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
  # SG can't be deleted while the service's ENI still exists; retry a few times.
  for i in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
      echo "    deleted $SG_ID"
      break
    fi
    echo "    waiting for ENI cleanup... ($i/6)"
    sleep 20
  done
fi

echo ">>> Detaching + deleting IAM execution role"
aws iam detach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1 || true
aws iam delete-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo " TEARDOWN COMPLETE"
echo " Double-check in the AWS console that nothing is still"
echo " running (ECS, EC2, CloudWatch). The GitHub Actions IAM"
echo " user is NOT deleted -- remove it manually in IAM if done."
echo "============================================================"
