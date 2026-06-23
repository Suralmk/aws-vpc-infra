# PROVIDER setup — credentials from AWS CLI profile locally, or env vars in CI
provider "aws" {
  region = var.region
}
