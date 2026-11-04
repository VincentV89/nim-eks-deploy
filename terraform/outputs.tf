output "endpoint_name" {
  description = "SageMaker endpoint name (null until an image has been deployed)"
  value       = one(aws_sagemaker_endpoint.nim[*].name)
}

output "served_model_name" {
  description = "Value to use for the `model` field in chat-completion requests"
  value       = var.served_model_name
}

output "region" {
  value = var.region
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "ngc_secret_arn" {
  value = aws_secretsmanager_secret.ngc.arn
}
