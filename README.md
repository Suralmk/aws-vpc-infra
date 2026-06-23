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
| `data.tf` | Looks up the latest Ubuntu 20.04 AMI and creates the SSH key pair used by EC2 instances. |
| `vpc.tf` | Provisions the VPC module — public, private app, and database subnets across two AZs, plus a NAT gateway and DB subnet group. |
| `security_groups.tf` | Defines firewall rules for the ALB (HTTP/HTTPS from internet), app EC2 (port 8000 from ALB only), RDS (Postgres from EC2 and bastion), bastion (SSH from your IP), and VPC endpoints (HTTPS from private subnets). |
| `iam.tf` | Creates an IAM role and instance profile for the backend EC2 so it can read DB credentials from Secrets Manager and send logs to CloudWatch. |
| `ec2.tf` | Launches the bastion host (public subnet, Postgres client installed) and the backend app instance (private subnet, Docker installed, IAM profile attached). |
| `alb.tf` | Creates the Application Load Balancer in public subnets, a target group with `/health` checks on port 8000, an HTTP listener, and attaches the backend EC2 to the target group. |
| `rds.tf` | Provisions a private, encrypted PostgreSQL RDS instance in the database subnets — no public access. |
| `vpc_endpoints.tf` | Adds interface VPC endpoints for Secrets Manager and CloudWatch Logs so private subnets can reach AWS services without going over the public internet. |
| `variables.tf` | Input variables: `region`, `environment`, `db_password`, and `bastion_allowed_cidr`. |
| `outputs.tf` | Prints useful values after apply: VPC ID, ALB DNS, bastion IP, RDS endpoint, backend private IP, SSH/psql commands, and the EC2 instance profile name. |
| `terraform.tfvars.example` | Example variable values — copy to `terraform.tfvars` and fill in your password and IP before running `terraform apply`. |

**Traffic flow:** Internet → ALB (public subnet) → backend EC2 (private subnet) → RDS (database subnet). The bastion is the only SSH entry point into the VPC.

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Python >= 3.11
- Node.js >= 18 (for CDK)
- AWS CDK: `npm install -g aws-cdk`

---

## Deploy

### 1. Bootstrap remote state

Create the S3 bucket and DynamoDB table for Terraform state before anything else.

```bash
aws s3api create-bucket --bucket aws-vpc-infra-tfstate --region us-east-1
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 2. Provision the VPC

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit db_password and bastion_allowed_cidr
terraform init
terraform plan
terraform apply
```

### 3. Connect to the database via bastion

```bash
# SSH to bastion
ssh -i your-key.pem ec2-user@<bastion-public-ip>

# From bastion, connect to RDS
psql -h <rds-private-endpoint> -U postgres -d appdb
```

### 4. Run the FastAPI app locally

```bash
cd app
pip install -r requirements.txt
export DATABASE_URL=postgresql://postgres:password@localhost:5432/appdb
uvicorn main:app --reload
```

### 5. Run Alembic migrations

```bash
alembic upgrade head
```

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
