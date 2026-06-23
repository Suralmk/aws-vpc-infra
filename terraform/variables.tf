variable "region" {
    description = "The AWS region we are deploying to"
    type        = string
    default     = "us-east-1"
}

variable "environment" {
  description = "Environment name — used in resource tags and names"
  type        = string
  default     = "dev"
}

variable "db_password" {
  type      = string
  sensitive = true  # hides it from terraform plan/apply output
}

variable "bastion_allowed_cidr" {
  description = "Your IP in CIDR format allowed to SSH to bastion — run: curl ifconfig.me"
  type        = string
}

variable "public_key" {
  description = "SSH public key for bastion access (contents of deployer-key.pub)"
  type        = string
}