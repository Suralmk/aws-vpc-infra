# aws-vpc-infra — common tasks for Terraform, local Docker, and AWS deploy
.DEFAULT_GOAL := help

TF_DIR     := terraform
AWS_REGION ?= us-east-1
IMAGE_TAG  ?= latest

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show available targets
	@echo ""
	@echo "Terraform (infra)"
	@echo "  make init       Initialize Terraform and backend"
	@echo "  make plan       Plan infrastructure changes"
	@echo "  make apply      Apply infrastructure changes"
	@echo "  make destroy    Tear down infrastructure"
	@echo "  make fmt        Format .tf files"
	@echo "  make validate   Validate Terraform config"
	@echo "  make output     Show Terraform outputs"
	@echo ""
	@echo "Docker (local dev)"
	@echo "  make up         Start local stack (docker compose)"
	@echo "  make down       Stop local stack"
	@echo "  make logs       Follow API / DB logs"
	@echo "  make build      Build local Docker images"
	@echo ""
	@echo "AWS (deploy app to EC2)"
	@echo "  make ecr-login  Log Docker into ECR"
	@echo "  make push       Build and push image to ECR"
	@echo "  make release    Build, push, deploy via SSM, smoke-test ALB"
	@echo ""
	@echo "Setup"
	@echo "  make tfvars     Create terraform.tfvars from example if missing"
	@echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────

.PHONY: tfvars
tfvars: ## Copy terraform.tfvars.example if terraform.tfvars is missing
	@test -f $(TF_DIR)/terraform.tfvars || \
		(cp $(TF_DIR)/terraform.tfvars.example $(TF_DIR)/terraform.tfvars && \
		echo "Created $(TF_DIR)/terraform.tfvars — edit it before make apply")

# ── Terraform ─────────────────────────────────────────────────────────────────

.PHONY: init plan apply destroy fmt validate output outputs

init: tfvars ## terraform init
	cd $(TF_DIR) && terraform init

plan: init ## terraform plan
	cd $(TF_DIR) && terraform plan

apply: init ## terraform apply
	cd $(TF_DIR) && terraform apply

destroy: ## terraform destroy
	cd $(TF_DIR) && terraform destroy

fmt: ## terraform fmt
	cd $(TF_DIR) && terraform fmt -recursive

validate: init ## terraform validate
	cd $(TF_DIR) && terraform validate

output: ## Show all terraform outputs
	cd $(TF_DIR) && terraform output

outputs: output ## Alias for output

# ── Docker (local) ────────────────────────────────────────────────────────────

.PHONY: up down logs build

up: ## docker compose up --build
	docker compose up --build

down: ## docker compose down
	docker compose down

logs: ## docker compose logs -f
	docker compose logs -f

build: ## docker compose build
	docker compose build

# ── AWS deploy ──────────────────────────────────────────────────────────────────

.PHONY: ecr-login push release

ecr-login: init ## Authenticate Docker with ECR
	@ECR=$$(cd $(TF_DIR) && terraform output -raw ecr_repository_url); \
	aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin "$${ECR%%/*}"

push: ecr-login ## Build and push image to ECR (IMAGE_TAG=$(IMAGE_TAG))
	@ECR=$$(cd $(TF_DIR) && terraform output -raw ecr_repository_url); \
	docker build -t $$ECR:$(IMAGE_TAG) -t $$ECR:latest .; \
	docker push $$ECR:$(IMAGE_TAG); \
	docker push $$ECR:latest; \
	echo "Pushed $$ECR:$(IMAGE_TAG)"

release: ## Full deploy: ECR push + SSM + ALB health check
	AWS_REGION=$(AWS_REGION) IMAGE_TAG=$(IMAGE_TAG) bash scripts/release.sh
