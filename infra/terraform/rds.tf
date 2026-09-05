resource "aws_db_subnet_group" "dispatch" {
  name       = "velocity-dispatch-${var.environment}"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "dispatch" {
  identifier     = "velocity-dispatch-${var.environment}"
  engine         = "postgres"
  engine_version = "16"

  # db.t4g.micro: Graviton burstable instance, in the RDS Free Tier bracket —
  # right-sized for a portfolio deploy, not for real order volume. The
  # README's load-test section documents how to read pg connection/CPU
  # metrics to decide when this actually needs to grow.
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "dispatch"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.dispatch.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Single-AZ + short backup retention: another deliberate cost cut for a
  # demo deployment. Flipping `multi_az = true` and raising
  # `backup_retention_period` is the whole change needed for production
  # durability — noted explicitly so it reads as a choice, not an oversight.
  multi_az                = false
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  publicly_accessible = false
}
