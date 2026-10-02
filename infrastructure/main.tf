# ==============================================================================
# Jobgether Remote Talent Optimization - Enterprise Infrastructure as Code (IaC)
# Target: AWS Terraform HCL | Amazon RDS PostgreSQL 16, S3 Lakehouse & IAM Roles
# Architecture: Isolated VPC Subnets, Server-Side Encryption, and Lifecycle Rules
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "jobgether-finance-linear-optimization-engine"
      TargetRole  = "Data Engineer"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

# -----------------------------------------------------------------------------
# 1. S3 Data Lakehouse for High-Throughput Columnar Telemetry (Parquet)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "telemetry_lake" {
  bucket        = "${var.s3_bucket_prefix}-${var.environment}"
  force_destroy = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "telemetry_crypto" {
  bucket = aws_s3_bucket.telemetry_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "telemetry_guard" {
  bucket                  = aws_s3_bucket.telemetry_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "telemetry_lifecycle" {
  bucket = aws_s3_bucket.telemetry_lake.id

  rule {
    id     = "archive-historical-sourcing-telemetry"
    status = "Enabled"

    filter {
      prefix = "telemetry/raw/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# -----------------------------------------------------------------------------
# 2. Managed Amazon RDS PostgreSQL 16 Multi-AZ Data Warehouse
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "sourcing_rds_subnets" {
  name        = "jobgether-sourcing-rds-subnet-group"
  description = "Isolated subnets across availability zones for Jobgether analytics"
  subnet_ids  = var.private_subnet_ids
}

resource "aws_security_group" "rds_sg" {
  name        = "jobgether-sourcing-rds-sg"
  description = "Inbound PostgreSQL access restricted to internal data pipeline workers"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL port from internal ECS/Glue ETL workers"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "telemetry_postgres" {
  identifier             = "jobgether-sourcing-dw-db"
  allocated_storage      = var.db_allocated_storage_gb
  max_allocated_storage  = var.db_max_allocated_storage_gb
  engine                 = "postgres"
  engine_version         = "16.1"
  instance_class         = var.db_instance_class
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.sourcing_rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false

  backup_retention_period = 14
  storage_encrypted       = true
  deletion_protection     = false
}

# -----------------------------------------------------------------------------
# 3. IAM Least-Privilege Execution Role & CloudWatch Telemetry Monitor
# -----------------------------------------------------------------------------
resource "aws_iam_role" "optimization_execution_role" {
  name = "jobgether-optimization-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = ["ecs-tasks.amazonaws.com", "glue.amazonaws.com"]
        }
      }
    ]
  })
}

resource "aws_iam_policy" "optimization_s3_policy" {
  name        = "jobgether-optimization-s3-access-policy"
  description = "Granular least-privilege permissions for Parquet lakehouse access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.telemetry_lake.arn,
          "${aws_s3_bucket.telemetry_lake.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_s3_policy" {
  role       = aws_iam_role.optimization_execution_role.name
  policy_arn = aws_iam_policy.optimization_s3_policy.arn
}

resource "aws_cloudwatch_log_group" "optimization_pipeline_logs" {
  name              = "/aws/jobgether/sourcing-optimization-pipeline"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_metric_alarm" "cpa_anomaly_alarm" {
  alarm_name          = "jobgether-sourcing-cpa-breach-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CostPerApplicantSurge"
  namespace           = "Jobgether/Optimization"
  period              = 300
  statistic           = "Average"
  threshold           = 120.0
  alarm_description   = "Triggers executive escalation when average CPA surges beyond threshold"
  treat_missing_data  = "notBreaching"
}