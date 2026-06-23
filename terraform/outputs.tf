output "VPC_Id" {
    description = "ID of the VPC"
    value       = module.vpc.vpc_id
}

output  "Load_Balancer_DNS" {
    value = aws_lb.app_alb.dns_name
    description = "Hit this URL in your browser to access the app. Traffic goes: Internet -> ALB (Public) -> EC2 (Private)"
}

output "bastion_public_ip" {
  description = "SSH to this IP to reach private resources"
  value       = aws_instance.bastion.public_ip
}

output  "RDS_Endpoint" {
    value = aws_db_instance.app_db.endpoint
    description = "Your EC2 connects to this internally. No internet required."
}
output "backend_private_ip" {
  description = "Private IP of the app EC2 instance"
  value       = aws_instance.backend_app.private_ip
}

# Handy SSH command printed after apply
output "ssh_to_bastion" {
  description = "Run this to SSH into the bastion"
  value       = "ssh ubuntu@${aws_instance.bastion.public_ip}"
}

# Handy psql command via bastion tunnel
output "psql_via_bastion" {
  description = "Run this FROM the bastion to connect to RDS"
  value       = "psql -h ${aws_db_instance.app_db.address} -U postgres -d appdb"
}

output "ec2_instance_profile_name" {
  description = "IAM instance profile attached to the backend EC2 for Secrets Manager access"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db_credentials.name
}