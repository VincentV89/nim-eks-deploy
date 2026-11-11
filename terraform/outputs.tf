output "sagemaker_endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value       = aws_sagemaker_endpoint.nim.name
}

output "sagemaker_endpoint_url" {
  description = "URL for invoking the SageMaker endpoint"
  value       = "https://runtime.sagemaker.${var.region}.amazonaws.com/endpoints/${aws_sagemaker_endpoint.nim.name}/invocations"
}

output "sagemaker_role_arn" {
  description = "ARN of the SageMaker execution IAM role"
  value       = aws_iam_role.sagemaker_execution.arn
}
