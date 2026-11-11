output "endpoint_name" {
  value = aws_sagemaker_endpoint.nim.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.nim.repository_url
}

output "invoke_example" {
  value = "aws sagemaker-runtime invoke-endpoint --endpoint-name ${aws_sagemaker_endpoint.nim.name} --region ${var.region} --content-type application/json --body fileb://request.json out.json"
}
