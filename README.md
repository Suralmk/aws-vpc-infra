# aws-vpc-infra

Infrastructure-as-code repository to provision a production-grade, three-tier AWS VPC with a private RDS, a bastion host, and an example FastAPI backend. This repo includes Terraform configuration, Docker-based local run instructions, and a Makefile to help you iterate quickly.

---

## Overview

This repository provisions a complete network foundation on AWS: three isolated subnet tiers across two availability zones, a private PostgreSQL database with no public endpoint, and a bastion host as the only entry point into the private network. Infrastructure is codified in Terraform under `terraform/`, and a small FastAPI app in `app/` demonstrates how the backend connects to the database. Use `docker-compose` for quick local testing and Terraform for cloud deployment.

---

## Architecture

![VPC architecture diagram](asset/vpc_architecture_diagram.svg)

---

## CIDR Plan

| Subnet   | CIDR         | AZ         | Tier         |
| -------- | ------------ | ---------- | ------------ |
| Public A | 10.0.1.0/24  | us-east-1a | Public       |
| Public B | 10.0.2.0/24  | us-east-1b | Public       |
| App A    | 10.0.10.0/24 | us-east-1a | Private app  |
| App B    | 10.0.11.0/24 | us-east-1b | Private app  |
| Data A   | 10.0.20.0/24 | us-east-1a | Private data |
| Data B   | 10.0.21.0/24 | us-east-1b | Private data |

---

## AWS Services Used

- VPC, subnets, route tables, internet gateway, NAT gateway
- Security groups (chained: ALB → app → RDS)
- RDS PostgreSQL (Multi-AZ, encrypted at rest, no public endpoint)
- EC2 bastion host with EC2 Instance Connect
- Secrets Manager for DB credentials (via VPC endpoint + IAM role)
- VPC interface endpoints for Secrets Manager and CloudWatch Logs

---

## Tech Stack

| Layer        | Tools                                  |
| ------------ | -------------------------------------- |
| IaC          | Terraform, AWS CDK (Python)            |
| Remote state | S3 + DynamoDB lock                     |
| Backend      | FastAPI, SQLAlchemy, psycopg2, Alembic |
| CI/CD        | GitHub Actions                         |

---

## Project Structure

```
aws-vpc-infra/
├── terraform/
│   ├── provider.tf
│   ├── data.tf
│   ├── vpc.tf
│   ├── security_groups.tf
│   ├── iam.tf
│   ├── ec2.tf
│   ├── alb.tf
│   ├── rds.tf
│   ├── secrets.tf
│   ├── vpc_endpoints.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── app/
│   ├── main.py
│   ├── database.py
│   ├── config.py
│   └── health.py
├── docker-compose.yml
├── Dockerfile
├── Makefile
└── README.md
```

---

## Terraform Files

Infrastructure is split into focused files so each layer of the stack is easy to find and read. Terraform loads every `.tf` file in the `terraform/` directory as a single configuration.

| File | What it does |
| ---- | ------------ |
| `provider.tf` | Configures the AWS provider (region and credentials profile). |
| `data.tf` | Looks up the latest Ubuntu 20.04 AMI and registers the SSH key pair (`aws_key_pair.deployer`) from `var.public_key`. |
| `vpc.tf` | Provisions the VPC module — public, private app, and database subnets across two AZs, plus a NAT gateway and DB subnet group. |
| `security_groups.tf` | Defines firewall rules for the ALB (HTTP/HTTPS from internet), app EC2 (port 8000 from ALB only), RDS (Postgres from EC2 and bastion), bastion (SSH from your IP), and VPC endpoints (HTTPS from private subnets). |
| `iam.tf` | Creates an IAM role and instance profile for the backend EC2 so it can read DB credentials from Secrets Manager and send logs to CloudWatch. |
| `ec2.tf` | Launches the bastion host (public subnet, Postgres client installed) and the backend app instance (private subnet, Docker installed, IAM profile attached). |
| `alb.tf` | Creates the Application Load Balancer in public subnets, a target group with `/health` checks on port 8000, an HTTP listener, and attaches the backend EC2 to the target group. |
| `rds.tf` | Provisions a private, encrypted PostgreSQL RDS instance in the database subnets — no public access. |
| `vpc_endpoints.tf` | Adds interface VPC endpoints for Secrets Manager and CloudWatch Logs so private subnets can reach AWS services without going over the public internet. |
| `variables.tf` | Input variables: `region`, `environment`, `db_password`, `bastion_allowed_cidr`, and `public_key`. |
| `outputs.tf` | Prints useful values after apply: VPC ID, ALB DNS, bastion IP, RDS endpoint, backend private IP, SSH/psql commands, and the EC2 instance profile name. |
| `terraform.tfvars.example` | Example variable values — copy to `terraform.tfvars` and fill in your password, IP, and SSH public key before running `terraform apply`. |

**Traffic flow:** Internet → ALB (public subnet) → backend EC2 (private subnet) → RDS (database subnet). The bastion is the only SSH entry point into the VPC.

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Python >= 3.11 (optional — for running the app outside Docker)
- Docker and Docker Compose (for local testing)
- An SSH key pair named **`deployer-key`** (see below)

---

## Step-by-step guide

### 1. Generate the SSH key pair

Terraform uploads your **public** key to AWS. You keep the **private** key on your machine to SSH into the bastion.

Use the name **`deployer-key`** so it matches this repo and the examples below.

**On Windows (PowerShell):**

```powershell
ssh-keygen -t rsa -b 4096 -f $env:USERPROFILE\.ssh\deployer-key -C "your-email@example.com"
```

**On WSL / Linux / macOS:**

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/deployer-key -C "your-email@example.com"
```

Press Enter to accept the default passphrase (or set one if you prefer).

This creates two files:

| File | Purpose |
| ---- | ------- |
| `deployer-key` | Private key — **never commit**; used for `ssh -i` |
| `deployer-key.pub` | Public key — paste into `terraform.tfvars` |

**WSL note:** If you run Terraform from WSL but generated keys in Windows, the key lives at:

```text
/mnt/c/Users/<YourWindowsUser>/.ssh/deployer-key
```

Copy the public key (one line):

```bash
# WSL — Windows key path
cat /mnt/c/Users/HP/.ssh/deployer-key.pub

# Or if you generated inside WSL
cat ~/.ssh/deployer-key.pub
```

---

### 2. Configure `terraform.tfvars`

`terraform.tfvars` is gitignored. Create it from the example:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set every variable:

```hcl
region = "us-east-1"

environment = "dev"   # or "production" — used in resource names and tags

db_password = "YourStrongPasswordHere"

# Your public IP in CIDR form — only this IP can SSH to the bastion
bastion_allowed_cidr = "203.0.113.10/32"

# Full contents of deployer-key.pub (single line, in quotes)
public_key = "ssh-rsa AAAA... your-email@example.com"
```

| Variable | What to set |
| -------- | ----------- |
| `region` | AWS region (default `us-east-1`) |
| `environment` | Label for resources, e.g. `dev` or `production`. Key pair name becomes `<environment>-deployer-key` |
| `db_password` | PostgreSQL master password for RDS |
| `bastion_allowed_cidr` | Your IP as `x.x.x.x/32`. Get it with `curl ifconfig.me` |
| `public_key` | Output of `cat deployer-key.pub` — **not** a file path |

**Important:** Do not use `file("~/.ssh/...")` in Terraform. WSL and Windows use different home directories, so a local file path often fails. Passing the key as a variable avoids that.

---

### 3. Bootstrap remote state (first time only)

Create the S3 bucket and DynamoDB table for Terraform state before anything else.

```bash
aws s3api create-bucket --bucket aws-vpc-infra-tfstate --region us-east-1
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

---

### 4. Provision the VPC

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

After apply, note the outputs (or run `terraform output`):

```bash
terraform output bastion_public_ip
terraform output ssh_to_bastion
terraform output Load_Balancer_DNS
terraform output RDS_Endpoint
terraform output psql_via_bastion
```

---

### 5. SSH into the bastion

The bastion runs **Ubuntu**, so the SSH user is **`ubuntu`** (not `ec2-user`).

**From WSL (Windows key on C: drive):**

```bash
ssh -i /mnt/c/Users/HP/.ssh/deployer-key ubuntu@<bastion-public-ip>
```

**From Linux / macOS:**

```bash
ssh -i ~/.ssh/deployer-key ubuntu@<bastion-public-ip>
```

**From Windows PowerShell:**

```powershell
ssh -i $env:USERPROFILE\.ssh\deployer-key ubuntu@<bastion-public-ip>
```

Replace `<bastion-public-ip>` with `terraform output -raw bastion_public_ip`.

**If SSH is refused:**

1. Confirm `bastion_allowed_cidr` in `terraform.tfvars` matches your **current** public IP (`curl ifconfig.me`).
2. Re-run `terraform apply` after updating the IP.
3. Confirm you are using the **private** key (`deployer-key`), not the `.pub` file.
4. On first connect, accept the host key fingerprint when prompted.

**Connect to RDS from the bastion** (postgres client is pre-installed):

```bash
psql -h <rds-endpoint-hostname> -U postgres -d appdb
```

Use the hostname from `terraform output RDS_Endpoint` (without the `:5432` port suffix). Password is the `db_password` from `terraform.tfvars`.

**Optional — SSH tunnel to RDS from your laptop** (without logging into bastion interactively):

```bash
ssh -i ~/.ssh/deployer-key -L 5433:<rds-hostname>:5432 ubuntu@<bastion-public-ip> -N
```

Then connect locally: `psql -h localhost -p 5433 -U postgres -d appdb`

---

### 6. Test the app locally (Docker)

Local development does **not** need AWS. The API reads `DATABASE_URL` from the environment (see `app/config.py`).

**6a. Environment file**

From the repo root:

```bash
cp .env.example .env
```

Edit `.env`:

```env
POSTGRES_USER=postgres
POSTGRES_PASSWORD=password
POSTGRES_DB=appdb
POSTGRES_PORT=5432
API_PORT=8000
DATABASE_URL=postgresql://postgres:password@localhost:5432/appdb
```

**6b. Start Postgres + API**

```bash
make up
# or: docker compose up --build
```

Wait until both containers are healthy, then test:

```bash
curl http://localhost:8000/health
curl http://localhost:8000/db-check
```

Expected: JSON with `"status": "healthy"` or `"status": "connected"`.

**6c. View logs / stop**

```bash
make logs    # follow container logs
make down    # stop and remove containers
```

---

### 7. Test the app locally (without Docker)

```bash
# Terminal 1 — Postgres only
docker compose up db

# Terminal 2 — API
cd app
python -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
export DATABASE_URL=postgresql://postgres:password@localhost:5432/appdb
uvicorn main:app --reload --port 8000
```

Open http://localhost:8000/health and http://localhost:8000/db-check.

---

### 8. Test the deployed stack on AWS

After `terraform apply` and the backend EC2 has finished user-data (Docker install), hit the load balancer:

```bash
curl http://$(terraform output -raw Load_Balancer_DNS)/health
```

The backend in production uses Secrets Manager (`ENV=production`, `SECRET_NAME` from `terraform output db_secret_name`). Local Docker uses `DATABASE_URL` instead.

---

## Deploy (quick reference)

### Provision and connect

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit all variables
terraform init && terraform plan && terraform apply
ssh -i ~/.ssh/deployer-key ubuntu@$(terraform output -raw bastion_public_ip)
```

See **Step-by-step guide** above for SSH key generation, `terraform.tfvars`, local Docker testing, and troubleshooting.

---

## Security Group Rules

| Group   | Inbound | Source             |
| ------- | ------- | ------------------ |
| ALB     | 443, 80 | 0.0.0.0/0          |
| App     | 8000    | ALB security group |
| RDS     | 5432    | App security group |
| Bastion | 22      | Your IP only       |

The app and data tiers have no inbound rules from the internet. The only path to RDS from outside the VPC is: your machine → bastion (SSH) → RDS (psql).

---

## API Endpoints

| Method | Path      | Description                   |
| ------ | --------- | ----------------------------- |
| GET    | /health   | Returns 200 OK                |
| GET    | /db-check | Runs a test query against RDS |

---

## CI/CD

On every pull request, GitHub Actions runs:

```
terraform fmt -check
terraform validate
terraform plan   ← plan output posted as PR comment
```

On merge to `main`:

```
terraform apply
```

---

## Teardown

```bash
cd terraform
terraform destroy
```

> Make sure to destroy before leaving resources idle — NAT Gateway and RDS are the main cost drivers.

---

## Key Concepts Demonstrated

- Subnet CIDR planning and AZ distribution
- NAT Gateway vs internet gateway distinction
- Security group ingress/egress chaining
- Multi-AZ RDS failover behaviour
- Remote Terraform state with locking
- RDS parameter groups and encryption at rest
- Bastion host as sole entry point to private network

---

## License

MIT
