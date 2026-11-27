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
  value = "aws sagemaker-runtime invoke-endpoint --region ${var.region} --endpoint-name ${aws_sagemaker_endpoint.nim.name} --content-type application/json --cli-binary-format raw-in-base64-out --body '{\"model\":\"meta/llama-3.1-8b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}' /dev/stdout"
}
