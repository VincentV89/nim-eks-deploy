output "endpoint_name" {
  value = aws_sagemaker_endpoint.nim.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "image_uri" {
  value = local.image_uri
}

output "invoke_example" {
  value = "aws sagemaker-runtime invoke-endpoint --endpoint-name ${aws_sagemaker_endpoint.nim.name} --region ${var.region} --content-type application/json --cli-binary-format raw-in-base64-out --body '{\"model\":\"meta/llama-3.1-8b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}' /dev/stdout"
}

output "ngc_secret_arn" {
  value = aws_secretsmanager_secret.ngc.arn
}
