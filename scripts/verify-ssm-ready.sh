#!/usr/bin/env bash
# Verify backend EC2 is running and registered with SSM before SendCommand.
set -euo pipefail

INSTANCE_ID="${1:?Usage: verify-ssm-ready.sh <instance-id>}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-300}"

echo "Checking EC2 instance: $INSTANCE_ID"

STATE="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)"

echo "EC2 state: $STATE"
if [[ "$STATE" != "running" ]]; then
  echo "ERROR: Instance must be running for SSM deploy (current: $STATE)"
  exit 1
fi

PROFILE="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text)"
echo "IAM instance profile: $PROFILE"
if [[ "$PROFILE" == "None" || -z "$PROFILE" ]]; then
  echo "ERROR: No IAM instance profile attached. Run: terraform apply"
  exit 1
fi

echo "Waiting for SSM agent (PingStatus=Online), up to ${MAX_WAIT_SECONDS}s..."
DEADLINE=$((SECONDS + MAX_WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  PING="$(aws ssm describe-instance-information \
    --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || true)"

  if [[ "$PING" == "Online" ]]; then
    echo "SSM agent is Online — ready to deploy."
    exit 0
  fi

  echo "SSM PingStatus: ${PING:-NotRegistered} (retrying...)"
  sleep 15
done

echo ""
echo "ERROR: Instance is not registered with SSM."
echo "Fix options:"
echo "  1) Recreate instance with SSM agent (recommended):"
echo "       cd terraform && terraform apply -replace=aws_instance.backend_app"
echo "  2) Or install agent on the running instance (via bastion SSH if configured)"
echo ""
aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --output table || true
exit 1
