# ==============================================================================
# Jobgether Remote Talent Optimization - Infrastructure Outputs
# Target: AWS Terraform HCL | Endpoints, ARNs and Identifiers
# ==============================================================================

output "s3_telemetry_lake_bucket_name" {
  description = "Canonical S3 Bucket identifier for historical sourcing Parquet telemetry"
  value       = aws_s3_bucket.telemetry_lake.id
}

output "s3_telemetry_lake_bucket_arn" {
  description = "Amazon Resource Name (ARN) for the telemetry data lake bucket"
  value       = aws_s3_bucket.telemetry_lake.arn
}

output "rds_postgres_endpoint" {
  description = "Direct connection endpoint for the PostgreSQL analytical data warehouse"
  value       = aws_db_instance.telemetry_postgres.endpoint
}

output "rds_postgres_database_name" {
  description = "Target database name hosting continuous rollup and cohort tables"
  value       = aws_db_instance.telemetry_postgres.db_name
}

output "iam_execution_role_arn" {
  description = "IAM role ARN assumed by Glue/ECS optimization ETL workers"
  value       = aws_iam_role.optimization_execution_role.arn
}

output "cloudwatch_cpa_anomaly_alarm_arn" {
  description = "CloudWatch alarm ARN monitoring sourcing CPA cost spikes"
  value       = aws_cloudwatch_metric_alarm.cpa_anomaly_alarm.arn
}