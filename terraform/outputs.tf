output "endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value       = aws_sagemaker_endpoint.nim.name
}

output "endpoint_url" {
  description = "URL for invoking the SageMaker endpoint via AWS SDK"
  value       = "https://runtime.sagemaker.${var.region}.amazonaws.com/endpoints/${aws_sagemaker_endpoint.nim.name}/invocations"
}

output "region" {
  description = "AWS region where the endpoint is deployed"
  value       = var.region
}
