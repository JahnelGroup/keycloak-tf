# configuration for the Postgres DB that keycloak uses
resource "aws_security_group" "keycloak_database_sg" {
  name        = "keycloak_database_sg"
  description = "Security group for keycloak db"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    description = "Allow access into db"
    # https://aws.amazon.com/premiumsupport/knowledge-center/connect-lambda-to-an-rds-instance/
    security_groups = [
      aws_security_group.keycloak.id,
      # aws_security_group.keycloak_db_secret_rotator.id,
      # var.bastion_sg_id
    ]
  }
}

# add 2 public subnets of the lgc vpc to the db subnet group
resource "aws_db_subnet_group" "keycloak_database_subnet_group" {
  name        = "keycloak_database_subnet_group"
  subnet_ids  = module.vpc.private_subnets
  description = "Subnet group for keycloak db instance"
}

# minimal postgres db for keycloak, will most likely have to scale this up as we get more users
resource "aws_db_instance" "keycloak_database" {
  allocated_storage    = 20
  apply_immediately    = true
  db_subnet_group_name = aws_db_subnet_group.keycloak_database_subnet_group.name
  engine               = "postgres"
  engine_version       = "14.4"
  # final_snapshot_identifier = "keycloak-database-final-snapshot" uncomment when done debugging
  identifier     = "keycloak-database"
  instance_class = "db.t3.micro"
  # kms_key_id             = aws_kms_key.keycloak_database_key.arn
  password               = data.aws_secretsmanager_random_password.keycloak_db_initial_pass.random_password
  port                   = 5432
  publicly_accessible    = false
  username               = "postgres"
  storage_encrypted      = true
  vpc_security_group_ids = [aws_security_group.keycloak_database_sg.id]

  # skip snapshots/backups for development/debugging only
  skip_final_snapshot     = true
  backup_retention_period = 0

  # ignore any changes to the password value
  lifecycle {
    ignore_changes = [
      password
    ]
    # prevent_destroy = true
  }
}

# DB secrets and rotation (initially don't set up rotation to test out tasks working with aws secrets manager)
data "aws_secretsmanager_random_password" "keycloak_db_initial_pass" {
  password_length     = 50
  exclude_punctuation = true
  include_space       = false
}

resource "aws_secretsmanager_secret" "keycloak_db_secrets" {
  name                    = "keycloak_db_secrets"
  recovery_window_in_days = 0 # for immediate deletion, remove once development is done
}

# initial secret setting
resource "aws_secretsmanager_secret_version" "keycloak_db_initial_secrets" {
  secret_id = aws_secretsmanager_secret.keycloak_db_secrets.id
  secret_string = jsonencode({
    host     = aws_db_instance.keycloak_database.address
    username = aws_db_instance.keycloak_database.username
    password = aws_db_instance.keycloak_database.password
    engine   = aws_db_instance.keycloak_database.engine
    port     = aws_db_instance.keycloak_database.port
    dbName   = "postgres"
  })

  # ignore any changes to the secret value
  lifecycle {
    ignore_changes = [
      secret_string
    ]
  }
}

