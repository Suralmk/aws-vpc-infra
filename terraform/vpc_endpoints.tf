# VPC INTERFACE ENDPOINTS (Allows privatesubnets to reach AWS services without going to the internet)
# 1, first interface for secrets manager to store DB credentials
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = { Name = "${var.environment}-secretsmanager-endpoint" }
}

# 2, second is for cloudwatch to store logs
resource "aws_vpc_endpoint" "cloudwatch" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true

  tags = { Name = "${var.environment}-cloudwatch-endpoint" }
}
