# ── Secrets Manager: DB credentials --
# Secret name matches SECRET_NAME in docker-compose.prod.yml
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.environment}/db/credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = aws_db_instance.app_db.username
    password = var.db_password
    host     = aws_db_instance.app_db.address
    port     = aws_db_instance.app_db.port
    dbname   = aws_db_instance.app_db.db_name
  })
}