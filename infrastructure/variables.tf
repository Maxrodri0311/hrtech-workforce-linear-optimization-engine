# ==============================================================================
# Jobgether Remote Talent Optimization - Infrastructure Variables
# Target: AWS Terraform HCL | Enterprise Multi-AZ Provisioning
# ==============================================================================

variable "aws_region" {
  description = "Target AWS deployment region for Jobgether data pipelines"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Target deployment environment tier (production, staging, test)"
  type        = string
  default     = "production"
}

variable "vpc_id" {
  description = "Virtual Private Cloud identifier hosting analytical workloads"
  type        = string
  default     = "vpc-0123456789abcdef0"
}

variable "vpc_cidr" {
  description = "VPC CIDR block for internal security group rules"
  type        = string
  default     = "10.100.0.0/16"
}

variable "private_subnet_ids" {
  description = "List of isolated private subnets across multi-AZ for RDS and Glue workers"
  type        = list(string)
  default     = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
}

variable "db_instance_class" {
  description = "Database compute sizing for PostgreSQL 16 analytics cluster"
  type        = string
  default     = "db.t4g.large"
}

variable "db_allocated_storage_gb" {
  description = "Initial storage allocated for PostgreSQL analytical lakehouse in GB"
  type        = number
  default     = 50
}

variable "db_max_allocated_storage_gb" {
  description = "Maximum autoscaling storage threshold for PostgreSQL telemetry in GB"
  type        = number
  default     = 250
}

variable "db_name" {
  description = "Target database name hosting sourcing telemetry and cohort tables"
  type        = string
  default     = "jobgether_optimization_dw"
}

variable "db_username" {
  description = "Master administrative username for PostgreSQL telemetry"
  type        = string
  default     = "jobgether_admin"
}

variable "db_password" {
  description = "Master administrative password for PostgreSQL telemetry"
  type        = string
  sensitive   = true
  default     = "JobgetherSecureOptimization2026!"
}

variable "s3_bucket_prefix" {
  description = "Naming prefix for canonical S3 Data Lakehouse telemetry buckets"
  type        = string
  default     = "jobgether-sourcing-telemetry-lake"
}

variable "log_retention_days" {
  description = "CloudWatch log retention window in days"
  type        = number
  default     = 90
}
