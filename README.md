# aws-vpc-infra

Infrastructure-as-code repository to provision a production-grade, three-tier AWS VPC with a private RDS, a bastion host, and an example FastAPI backend. This repo includes reusable Terraform modules, an AWS CDK reference, and Docker-based local run instructions to help you iterate quickly.

---

## Overview

This repository provisions a complete network foundation on AWS: three isolated subnet tiers across two availability zones, a private PostgreSQL database with no public endpoint, and a bastion host as the only entry point into the private network. Infrastructure is codified primarily with Terraform (reusable modules live under `terraform/modules/`), an AWS CDK reference exists in `cdk/`, and a small FastAPI app in `app/` demonstrates how the backend connects to the database. Use `docker-compose` for quick local testing and Terraform for cloud deployment.

---

## Architecture

```
Internet
    │
Internet Gateway
    │
┌───┴────────────────────────────────────────────┐
│  VPC  10.0.0.0/16                              │
│                                                │
│  ┌─────────────────────────────────────────┐  │
│  │  Public tier                            │  │
│  │  Bastion EC2 │ NAT Gateway │ ALB        │  │
│  │  10.0.1.0/24 (AZ-A)                    │  │
│  │  10.0.2.0/24 (AZ-B)                    │  │
│  └──────────────┬──────────────────────────┘  │
│                 │ (outbound via NAT)           │
│  ┌──────────────┴──────────────────────────┐  │
│  │  Private app tier                       │  │
│  │  ECS / EC2 workloads                    │  │
│  │  10.0.10.0/24 (AZ-A)                   │  │
│  │  10.0.11.0/24 (AZ-B)                   │  │
│  └──────────────┬──────────────────────────┘  │
│                 │                             │
│  ┌──────────────┴──────────────────────────┐  │
│  │  Private data tier                      │  │
│  │  RDS PostgreSQL Multi-AZ                │  │
│  │  10.0.20.0/24 (AZ-A) primary           │  │
│  │  10.0.21.0/24 (AZ-B) standby           │  │
│  └─────────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

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
- VPC Flow Logs → CloudWatch Logs
- SSM Parameter Store for secrets

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
│   ├── modules/
│   │   └── vpc/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   ├── envs/
│   │   └── dev/
│   │       ├── main.tf
│   │       └── terraform.tfvars
│   └── backend.tf
├── cdk/
│   ├── app.py
│   └── stacks/
│       └── vpc_stack.py
├── app/
│   ├── main.py
│   ├── database.py
│   ├── config.py
│   └── alembic/
├── .github/
│   └── workflows/
│       └── terraform.yml
└── README.md
```

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
cd terraform/envs/dev
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
cd terraform/envs/dev
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
