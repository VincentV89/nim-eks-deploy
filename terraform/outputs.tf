output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "endpoint_name" {
  value = aws_sagemaker_endpoint.nim.name
}

output "invoke_example" {
  value = "python scripts/load_test.py ${aws_sagemaker_endpoint.nim.name} --region ${var.region} --rps 1 --duration 5"
}
