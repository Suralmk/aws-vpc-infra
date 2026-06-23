# Store RDS connection details in Secrets Manager after the database is created.
# The backend EC2 reads this secret at runtime (see app/config.py).

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.environment}/db/credentials"
  description = "RDS PostgreSQL credentials for ${var.environment} backend app"

  tags = {
    Name = "${var.environment}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = aws_db_instance.app_db.username
    password = var.db_password
    engine   = "postgres"
    host     = aws_db_instance.app_db.address
    port     = aws_db_instance.app_db.port
    dbname   = aws_db_instance.app_db.db_name
  })
}
