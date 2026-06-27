#!/usr/bin/env bash
# Reads deploy targets from Terraform remote state, with AWS CLI fallbacks.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-production}"

cd "$(dirname "$0")/../terraform"

terraform init -input=false

echo "=== Terraform outputs in remote state ==="
terraform output || true

read_tf_output() {
  local name="$1"
  terraform output -raw "$name" 2>/dev/null || true
}

ECR_REPO="$(read_tf_output ecr_repository_url)"
DB_SECRET="$(read_tf_output db_secret_name)"
BACKEND_ID="$(read_tf_output backend_instance_id)"
ALB_DNS="$(read_tf_output Load_Balancer_DNS)"

# Fallback to AWS API when state is behind (e.g. ECR added in code but apply not run yet)
if [[ -z "$ECR_REPO" ]]; then
  echo "ecr_repository_url missing from state — trying AWS CLI..."
  ECR_REPO="$(aws ecr describe-repositories \
    --repository-names "${ENVIRONMENT}-aws-vpc-infra-api" \
    --region "$AWS_REGION" \
    --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null || true)"
fi

if [[ -z "$BACKEND_ID" || "$BACKEND_ID" == "None" ]]; then
  echo "backend_instance_id missing from state — trying AWS CLI..."
else
  STATE_OK="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$BACKEND_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || true)"
  case "$STATE_OK" in
    running|pending|stopping|stopped)
      if [[ "$STATE_OK" != "running" ]]; then
        echo "NOTE: State instance $BACKEND_ID is not running yet (status: $STATE_OK)."
        echo "      Keeping instance id from state — verify-ssm-ready.sh will wait or report."
      fi
      ;;
    terminated|shutting-down|"")
      echo "WARNING: State instance $BACKEND_ID is gone or terminating (status: ${STATE_OK:-not found})."
      BACKEND_ID=""
      ;;
    *)
      echo "WARNING: State instance $BACKEND_ID has unexpected status: $STATE_OK"
      ;;
  esac
fi

if [[ -z "$BACKEND_ID" || "$BACKEND_ID" == "None" ]]; then
  BACKEND_ID="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${ENVIRONMENT}-backend-app" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)"
  if [[ -n "$BACKEND_ID" && "$BACKEND_ID" != "None" ]]; then
    echo "Using running instance from AWS API: $BACKEND_ID"
    echo "Run: cd terraform && terraform apply  (to sync remote state)"
  fi
fi

if [[ -z "$DB_SECRET" ]]; then
  DB_SECRET="${ENVIRONMENT}/db/credentials"
  echo "Using default db_secret_name: $DB_SECRET"
fi

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
  ALB_DNS="$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --names "${ENVIRONMENT}-app-alb" \
    --query 'LoadBalancers[0].DNSName' \
    --output text 2>/dev/null || true)"
fi

validate() {
  local name="$1"
  local value="$2"
  local pattern="$3"
  if [[ -z "$value" || "$value" == "None" ]]; then
    echo "ERROR: $name is empty."
    return 1
  fi
  if [[ ! "$value" =~ $pattern ]]; then
    echo "ERROR: $name has invalid value: $value"
    return 1
  fi
  return 0
}

validate "ecr_repository_url" "$ECR_REPO" '^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9._/-]+$' || FAILED=1
validate "backend_instance_id" "$BACKEND_ID" '^i-[a-f0-9]+$' || FAILED=1
validate "db_secret_name" "$DB_SECRET" '.+' || FAILED=1
validate "alb_dns" "$ALB_DNS" '.+\.elb\.amazonaws\.com$' || FAILED=1

if [[ "${FAILED:-0}" -eq 1 ]]; then
  echo ""
  echo "Deploy prerequisites missing. Run locally or via terraform-apply workflow:"
  echo "  cd terraform"
  echo "  terraform init -input=false"
  echo "  terraform apply"
  echo ""
  echo "This creates ECR, SSM permissions, and writes outputs to remote state."
  exit 1
fi

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"
{
  echo "ecr_repository_url=$ECR_REPO"
  echo "db_secret_name=$DB_SECRET"
  echo "backend_instance_id=$BACKEND_ID"
  echo "alb_dns=$ALB_DNS"
} >> "$GITHUB_OUTPUT"

echo "ecr_repository_url=$ECR_REPO"
echo "backend_instance_id=$BACKEND_ID"
echo "db_secret_name=$DB_SECRET"
echo "alb_dns=$ALB_DNS"
