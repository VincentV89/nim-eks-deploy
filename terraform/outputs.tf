output "endpoint_name" {
  value = aws_sagemaker_endpoint.nim.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "ngc_secret_arn" {
  value = aws_secretsmanager_secret.ngc_api_key.arn
}

output "invoke_example" {
  value = "aws sagemaker-runtime invoke-endpoint --region ${var.region} --endpoint-name ${aws_sagemaker_endpoint.nim.name} --content-type application/json --cli-binary-format raw-in-base64-out --body '{\"model\":\"${var.served_model_name}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}' /dev/stdout"
}

output "region" {
  value = var.region
}
