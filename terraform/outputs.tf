output "endpoint_name" {
  description = "SageMaker endpoint name (null until an image has been deployed)"
  value       = one(aws_sagemaker_endpoint.nim[*].name)
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "ngc_secret_arn" {
  value = aws_secretsmanager_secret.ngc.arn
}
