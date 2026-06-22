import os

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres:password@localhost:5432/appdb",
)

APP_NAME = "aws-vpc-infra"
APP_VERSION = "1.0.0"
