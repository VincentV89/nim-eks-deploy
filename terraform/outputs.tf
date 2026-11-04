output "region" {
  value = var.region
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "ngc_secret_arn" {
  value = aws_secretsmanager_secret.ngc.arn
}

output "endpoint_name" {
  value = local.deploy_endpoint ? aws_sagemaker_endpoint.nim[0].name : null
}

output "served_model_name" {
  value = var.served_model_name
}

output "test_command" {
  value = local.deploy_endpoint ? "aws sagemaker-runtime invoke-endpoint --region ${var.region} --endpoint-name ${aws_sagemaker_endpoint.nim[0].name} --content-type application/json --cli-binary-format raw-in-base64-out --body '{\"model\":\"${var.served_model_name}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}' /dev/stdout" : null
}
