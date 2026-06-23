#!/usr/bin/env bash
# Runs on the backend EC2 instance (via SSM) to pull the API image and restart the container.
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${SECRET_NAME:?SECRET_NAME is required}"

REGISTRY="${IMAGE%%/*}"

echo "Logging in to ECR (${REGISTRY})..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$REGISTRY"

echo "Pulling ${IMAGE}..."
docker pull "$IMAGE"

echo "Restarting API container..."
docker stop aws-vpc-infra-api 2>/dev/null || true
docker rm aws-vpc-infra-api 2>/dev/null || true

docker run -d \
  --name aws-vpc-infra-api \
  --restart unless-stopped \
  -p 8000:8000 \
  -e ENV=production \
  -e AWS_REGION="$AWS_REGION" \
  -e SECRET_NAME="$SECRET_NAME" \
  "$IMAGE"

echo "Waiting for /health..."
for _ in $(seq 1 12); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
    echo "Deploy successful — app is healthy."
    exit 0
  fi
  sleep 5
done

echo "Health check failed. Container logs:"
docker logs aws-vpc-infra-api --tail 80
exit 1
