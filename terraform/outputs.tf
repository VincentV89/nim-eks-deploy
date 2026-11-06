output "endpoint_name" {
  value = aws_sagemaker_endpoint.nim.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "invoke_example" {
  value = "./scripts/invoke.sh ${aws_sagemaker_endpoint.nim.name} 'Hello'"
}
