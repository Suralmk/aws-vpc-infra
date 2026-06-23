# RDS Database - Isolated database that only accepts traffic/request from ec2
resource "aws_db_instance" "app_db" {
  identifier             = "prod-db"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "appdb"
  username               = "postgres"
  password               = var.db_password
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  publicly_accessible = false
  multi_az            = false
  storage_encrypted   = true # This is a free feature and should always be enabled

  skip_final_snapshot = true # we doing this for testing

  tags = {
    Name = "Production-PostgreSQL"
  }
}
