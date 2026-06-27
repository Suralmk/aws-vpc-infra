# aws-vpc-infra

A production-style AWS three-tier VPC with a private FastAPI backend, PostgreSQL RDS, and full CI/CD — all defined in Terraform and deployable from GitHub Actions without SSH access to private instances.

**What makes this project stand out:**

- **Private-by-default networking** — the API and database live in private subnets; only the load balancer and bastion are reachable from outside the VPC.
- **No SSH deploys** — GitHub Actions pushes container images to ECR and deploys to the private EC2 instance through **AWS Systems Manager (SSM)**, not through the bastion.
- **Secrets, not env files in production** — RDS credentials are stored in **Secrets Manager** and read at runtime via an IAM instance profile and VPC endpoints.
- **Remote Terraform state** — infrastructure state lives in **S3** with **DynamoDB** locking, so CI and local runs share one source of truth.
- **End-to-end health checks** — the FastAPI app validates application and database connectivity; the ALB and deploy pipeline both target `/health`.

---

## How the system works

End users and operators interact with different entry points. Application traffic never touches the bastion.

```text
Internet
   │
   ▼
Application Load Balancer (public subnets, HTTP :80)
   │
   ▼
Backend EC2 + Docker (private app subnet, :8000)
   │                    │
   │                    ├── Secrets Manager (VPC endpoint) ── DB credentials
   │                    ├── ECR (via NAT) ── container images
   │                    └── SSM endpoints ── deploy commands from CI
   ▼
RDS PostgreSQL (private database subnets, :5432)

Operator laptop ──SSH──► Bastion (public subnet) ──psql──► RDS
GitHub Actions ──SSM──► Backend EC2 (no bastion required)
```

### Request path (live API)

1. A client calls `http://<alb-dns>/health` or `/db-check`.
2. The **Application Load Balancer** in a public subnet forwards HTTP to the backend EC2 on port **8000**.
3. The **FastAPI** container on EC2 loads `SECRET_NAME` from **Secrets Manager** (over a VPC interface endpoint), builds a database URL, and queries **RDS**.
4. The ALB target group health check also uses `/health`; unhealthy targets are removed from rotation.

### Deploy path (CI/CD)

1. A push to `main` (or a manual workflow run) triggers **Deploy API** in GitHub Actions.
2. The workflow reads `ecr_repository_url`, `backend_instance_id`, and `db_secret_name` from **Terraform remote state** (`scripts/read-infra-outputs.sh`).
3. Docker builds the API image and pushes it to **ECR**.
4. `scripts/verify-ssm-ready.sh` confirms the backend instance is running and registered in SSM.
5. **SSM Run Command** runs `scripts/deploy.sh` on the private instance: ECR login, `docker pull`, restart container with `ENV=production` and `SECRET_NAME`.
6. A smoke test curls `http://<alb-dns>/health`.

Infrastructure changes follow a separate path: pushes to `terraform/**` run **terraform-apply.yml**, which executes `terraform apply` against remote state.

---

## AWS services

| Service | Role in this project |
| ------- | -------------------- |
| **VPC** | `10.0.0.0/16` network with public, private app, and database subnets across two AZs |
| **Internet Gateway** | Public subnet outbound/inbound internet (ALB, bastion) |
| **NAT Gateway** | Outbound internet for private subnets (ECR image pulls, package installs during bootstrap) |
| **Application Load Balancer** | Public HTTP entry point; health checks on `/health` |
| **EC2 (backend)** | Private Ubuntu instance; runs Docker API container; SSM-managed |
| **EC2 (bastion)** | Public jump host; Postgres client for RDS access; SSH from your IP only |
| **RDS PostgreSQL** | Private Multi-AZ-capable database; encrypted; no public endpoint |
| **ECR** | Stores API Docker images for production deploys |
| **Secrets Manager** | Stores RDS host, user, password, database name |
| **IAM** | EC2 instance profile (Secrets Manager, ECR read, SSM, CloudWatch); GitHub Actions user for CI |
| **Systems Manager** | Registers backend EC2; `SendCommand` for deploys without SSH |
| **VPC interface endpoints** | Private access to Secrets Manager, CloudWatch Logs, SSM, SSM Messages, EC2 Messages |
| **S3 + DynamoDB** | Terraform remote state bucket and state locking table |

---

## Networking design

Traffic is segmented by subnet tier and **security groups** (firewalls attached to resources, not subnets).

| Tier | Subnets | Routing | What runs here |
| ---- | ------- | ------- | -------------- |
| **Public** | `10.0.1.0/24`, `10.0.2.0/24` | Internet Gateway | ALB, bastion, NAT Gateway |
| **Private app** | `10.0.10.0/24`, `10.0.11.0/24` | NAT Gateway (outbound) | Backend EC2, VPC endpoints |
| **Private data** | `10.0.20.0/24`, `10.0.21.0/24` | No internet route | RDS only |

**Security group chain**

| Group | Inbound allowed from |
| ----- | -------------------- |
| ALB | Internet (`0.0.0.0/0`) on 80/443 |
| App EC2 | ALB security group on 8000 |
| RDS | App EC2 and bastion security groups on 5432 |
| Bastion | Your IP (`bastion_allowed_cidr`) on 22 |
| VPC endpoints | Private subnet CIDRs on 443 |

The app and database tiers have **no** inbound rules from the internet. RDS is reachable from the app EC2 and bastion only.

**Private AWS API access**

Interface VPC endpoints with private DNS let the backend instance reach Secrets Manager, CloudWatch Logs, and SSM without sending that traffic to the public internet. ECR pulls use the NAT Gateway during deploy and bootstrap.

---

## Terraform

All infrastructure is declared under `terraform/`. Terraform loads every `.tf` file in that directory as a single configuration — there is no need to apply files individually.

### Remote state

State is stored remotely (see `terraform/backend.tf`):

- **S3 bucket:** `aws-vpc-infra-tfstate`
- **State key:** `production/terraform.tfstate`
- **Locking:** DynamoDB table `terraform-locks`

Bootstrap once before the first `terraform init`:

```bash
bash scripts/bootstrap-tf-backend.sh
cd terraform
terraform init -migrate-state   # if moving from local state
```

### How Terraform is applied

| Method | When | Command / workflow |
| ------ | ---- | ------------------ |
| **Local** | Development, one-off fixes | `cd terraform && terraform init && terraform plan && terraform apply` |
| **GitHub Actions** | Push to `main` changing `terraform/**` | `.github/workflows/terraform-apply.yml` runs `terraform apply -auto-approve` |
| **Pull request** | Validation only | `.github/workflows/pull-request.yml` runs `fmt`, `validate`, and `plan` |

Sensitive inputs (`db_password`, `public_key`) are passed via environment variables in CI (`TF_VAR_*` secrets) or `terraform.tfvars` locally (gitignored).

### Terraform files

| File | Purpose |
| ---- | ------- |
| `backend.tf` | S3 backend and provider version constraints |
| `provider.tf` | AWS provider configuration |
| `data.tf` | Ubuntu AMI lookup and SSH key pair |
| `vpc.tf` | VPC module — subnets, IGW, NAT, DB subnet group |
| `security_groups.tf` | ALB, app, RDS, bastion, VPC endpoint security groups |
| `iam.tf` | EC2 role, instance profile, managed policy attachments (Secrets Manager, SSM, ECR, CloudWatch) |
| `ec2.tf` | Bastion and backend instances; backend `user_data` installs Docker and SSM agent (snap) |
| `alb.tf` | ALB, target group (`/health`), listener, target attachment |
| `rds.tf` | PostgreSQL instance in database subnets |
| `secrets.tf` | Secrets Manager secret for DB credentials |
| `ecr.tf` | ECR repository and lifecycle policy |
| `vpc_endpoints.tf` | Interface endpoints for Secrets Manager, Logs, SSM, SSM Messages, EC2 Messages |
| `variables.tf` | `region`, `environment`, `db_password`, `bastion_allowed_cidr`, `public_key` |
| `outputs.tf` | ALB DNS, instance IDs, RDS endpoint, ECR URL, SSH helpers |

After `terraform apply`, use `terraform output` for connection details. Deploy workflows read the same values from remote state via `scripts/read-infra-outputs.sh`.

---

## Application

| Layer | Local (`docker-compose.yml`) | AWS production |
| ----- | ---------------------------- | -------------- |
| Runtime | Docker Compose | Docker on private EC2 |
| Image | Built locally | ECR (`{environment}-aws-vpc-infra-api`) |
| Database | Postgres container | RDS PostgreSQL |
| Credentials | `DATABASE_URL` in `.env` | `ENV=production` + `SECRET_NAME` → Secrets Manager |
| Exposure | `localhost:8000` | ALB → EC2:8000 |

**API endpoints**

| Method | Path | Description |
| ------ | ---- | ----------- |
| GET | `/health` | Application + infrastructure health (used by ALB and CI) |
| GET | `/db-check` | Database connectivity check |

**Verify the live API**

```bash
export AWS_REGION=us-east-1
ALB=$(cd terraform && terraform output -raw Load_Balancer_DNS)

curl -fsS "http://$ALB/health"
curl -fsS "http://$ALB/db-check"
```

**Verify AWS resources**

```bash
INSTANCE_ID=$(cd terraform && terraform output -raw backend_instance_id)

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text

aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' --output text

TG_ARN=$(aws elbv2 describe-target-groups --names production-app-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN"
```

Expect: EC2 `running`, SSM `Online`, target health `healthy`.

---

## Project structure

```text
aws-vpc-infra/
├── terraform/          # All infrastructure (.tf files)
├── app/                # FastAPI application
├── scripts/
│   ├── bootstrap-tf-backend.sh
│   ├── read-infra-outputs.sh
│   ├── verify-ssm-ready.sh
│   └── deploy.sh       # Runs on EC2 via SSM
├── .github/workflows/  # PR checks, terraform apply, deploy
├── docs/               # GitHub Actions IAM policy example
├── Dockerfile
├── docker-compose.yml
└── Makefile
```

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Docker and Docker Compose (local testing)
- SSH key pair **`deployer-key`** for bastion access (see below)

---

## Quick start

### 1. SSH key pair

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/deployer-key -C "your-email@example.com"
cat ~/.ssh/deployer-key.pub   # paste into terraform.tfvars
```

### 2. Configure variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — set `region`, `environment`, `db_password`, `bastion_allowed_cidr` (your IP as `x.x.x.x/32`), and `public_key` (full line from `.pub` file, not a file path).

### 3. Bootstrap state and apply

```bash
bash scripts/bootstrap-tf-backend.sh
cd terraform
terraform init
terraform plan
terraform apply
```

### 4. Connect to bastion

```bash
ssh -i ~/.ssh/deployer-key ubuntu@$(terraform output -raw bastion_public_ip)
```

From the bastion, connect to RDS: `psql -h <rds-host> -U postgres -d appdb` (password from `terraform.tfvars`).

### 5. Test locally (optional)

```bash
cp .env.example .env
make up
curl http://localhost:8000/health
```

---

## CI/CD (GitHub Actions)

| Workflow | Trigger | Action |
| -------- | ------- | ------ |
| `pull-request.yml` | PR to `main` | Docker build + health test; Terraform fmt/validate/plan |
| `terraform-apply.yml` | Push to `main` (`terraform/**`) or manual | `terraform apply` |
| `deploy.yml` | Push to `main` (non-terraform paths) or manual | Build → ECR → SSM deploy → ALB smoke test |

### One-time GitHub setup

1. Bootstrap remote state (see above).
2. Create IAM user `github-actions-aws-vpc-infra` with policy from `docs/github-actions-iam-policy.json`.
3. Repository **Secrets:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `TF_VAR_db_password`, `TF_VAR_public_key`.
4. Repository **Variables:** `AWS_REGION`, `ENVIRONMENT`, `BASTION_ALLOWED_CIDR`.

Deploy does **not** require opening the bastion to GitHub — SSM reaches the private instance directly.

---

## Teardown

```bash
cd terraform
terraform destroy
```

NAT Gateway and RDS are the main ongoing cost drivers. Destroy when not in use.

---

## Key concepts

- Three-tier subnet design with AZ redundancy
- Security group chaining instead of wide-open rules
- NAT Gateway vs Internet Gateway
- Private RDS with no public endpoint
- VPC endpoints for AWS APIs from private subnets
- IAM instance profiles for runtime credentials
- SSM-based deploys to instances without public IPs
- Remote Terraform state with locking

---

## CIDR plan

| Subnet | CIDR | AZ | Tier |
| ------ | ---- | -- | ---- |
| Public A | 10.0.1.0/24 | us-east-1a | Public |
| Public B | 10.0.2.0/24 | us-east-1b | Public |
| App A | 10.0.10.0/24 | us-east-1a | Private app |
| App B | 10.0.11.0/24 | us-east-1b | Private app |
| Data A | 10.0.20.0/24 | us-east-1a | Private data |
| Data B | 10.0.21.0/24 | us-east-1b | Private data |

VPC CIDR: `10.0.0.0/16`

---

## License

MIT
