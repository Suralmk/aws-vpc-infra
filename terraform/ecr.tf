# ── ECR Repository for the API Docker image ──
# GitHub Actions builds the FastAPI app, pushes it here, and the backend EC2
# pulls from this registry on deploy (see scripts/deploy.sh and .github/workflows/deploy.yml).
# The EC2 instance profile has AmazonEC2ContainerRegistryReadOnly to pull images.

resource "aws_ecr_repository" "app" {
  name                 = "${var.environment}-aws-vpc-infra-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.environment}-api-ecr"
  }
}

# ── Lifecycle policy — prune old images to control storage cost ──
# Keeps the 10 most recent images; older tags are expired automatically.

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
