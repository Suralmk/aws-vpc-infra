import json
import os

import boto3

APP_NAME = "aws-vpc-infra"
APP_VERSION = "1.0.0"


def get_database_url() -> str:
    # Local dev uses DATABASE_URL from docker-compose or .env
    if os.getenv("ENV") != "production":
        return os.getenv(
            "DATABASE_URL",
            "postgresql://postgres:password@localhost:5432/appdb",
        )

    secret_name = os.getenv("SECRET_NAME")
    if not secret_name:
        raise RuntimeError("SECRET_NAME is required when ENV=production")

    region = os.getenv("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    secret = client.get_secret_value(SecretId=secret_name)
    creds = json.loads(secret["SecretString"])

    return (
        f"postgresql://{creds['username']}:{creds['password']}"
        f"@{creds['host']}:{creds['port']}/{creds['dbname']}"
    )


DATABASE_URL = get_database_url()
