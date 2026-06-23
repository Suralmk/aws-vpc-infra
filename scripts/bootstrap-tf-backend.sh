#!/usr/bin/env bash
# Creates the S3 bucket and DynamoDB table required by terraform/backend.tf.
# Run once per AWS account before: terraform init -migrate-state
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="${TF_STATE_BUCKET:-aws-vpc-infra-tfstate}"
LOCK_TABLE="${TF_LOCK_TABLE:-terraform-locks}"

echo "Region:      $AWS_REGION"
echo "S3 bucket:   $BUCKET_NAME"
echo "DynamoDB:    $LOCK_TABLE"
echo ""

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "S3 bucket already exists: $BUCKET_NAME"
else
  echo "Creating S3 bucket..."
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "S3 bucket created."
fi

if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "DynamoDB table already exists: $LOCK_TABLE"
else
  echo "Creating DynamoDB lock table..."
  aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  echo "Waiting for table to become active..."
  aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$AWS_REGION"
  echo "DynamoDB table created."
fi

echo ""
echo "Backend ready. Next steps:"
echo "  cd terraform"
echo "  terraform init -migrate-state   # if you have local terraform.tfstate"
echo "  terraform init -input=false       # if starting fresh"
