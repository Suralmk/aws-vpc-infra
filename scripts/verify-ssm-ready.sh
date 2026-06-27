#!/usr/bin/env bash
# Verify backend EC2 is running and registered with SSM before SendCommand.
set -euo pipefail

INSTANCE_ID="${1:?Usage: verify-ssm-ready.sh <instance-id>}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-300}"

echo "Checking EC2 instance: $INSTANCE_ID (region: $AWS_REGION)"

STATE="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || true)"

if [[ -z "$STATE" || "$STATE" == "None" ]]; then
  echo "ERROR: Instance $INSTANCE_ID not found in region $AWS_REGION."
  echo "Your infra is in us-east-1. Run: export AWS_REGION=us-east-1"
  echo "Or: aws configure set region us-east-1"
  exit 1
fi

echo "EC2 state: $STATE"
if [[ "$STATE" == "stopped" ]]; then
  echo ""
  echo "Instance is stopped. Either start it:"
  echo "  aws ec2 start-instances --region $AWS_REGION --instance-ids $INSTANCE_ID"
  echo ""
  echo "Or recreate with SSM agent (recommended if never deployed via GitHub):"
  echo "  cd terraform && terraform apply -replace=aws_instance.backend_app"
  exit 1
fi
if [[ "$STATE" == "pending" || "$STATE" == "stopping" ]]; then
  echo "Waiting for instance to reach running (current: $STATE), up to ${MAX_WAIT_SECONDS}s..."
  DEADLINE=$((SECONDS + MAX_WAIT_SECONDS))
  while (( SECONDS < DEADLINE )); do
    STATE="$(aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || true)"
    if [[ "$STATE" == "running" ]]; then
      echo "EC2 state: running"
      break
    fi
    if [[ "$STATE" == "stopped" ]]; then
      echo "ERROR: Instance stopped while waiting (was $STATE)."
      exit 1
    fi
    echo "EC2 state: $STATE (retrying...)"
    sleep 15
  done
fi
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
echo ""
echo "Common causes:"
echo "  - Instance launched before SSM agent was added to user_data (user_data runs only on first boot)"
echo "  - terraform apply not run after adding SSM VPC endpoints / IAM policy (deploy.yml does not apply Terraform)"
echo "  - user_data failed before SSM install (check: aws ec2 get-console-output --instance-id $INSTANCE_ID)"
echo ""
echo "Fix options:"
echo "  1) Apply latest Terraform, then recreate the backend instance (recommended):"
echo "       cd terraform && terraform apply"
echo "       terraform apply -replace=aws_instance.backend_app"
echo "     Wait 2–5 min, then re-run deploy."
echo "  2) Or install the agent on the running instance (via bastion SSH if configured)"
echo ""
aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --output table || true
exit 1
