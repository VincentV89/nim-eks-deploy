output "sagemaker_endpoint_name" {
  description = "Name of the deployed SageMaker endpoint"
  value       = aws_sagemaker_endpoint.nim.name
}

output "sagemaker_endpoint_url" {
  description = "URL for invoking the SageMaker endpoint"
  value       = "https://runtime.sagemaker.${var.region}.amazonaws.com/endpoints/${aws_sagemaker_endpoint.nim.name}/invocations"
}

output "invoke_command" {
  description = "Example AWS CLI command to invoke the endpoint"
  value       = "aws sagemaker-runtime invoke-endpoint --endpoint-name ${aws_sagemaker_endpoint.nim.name} --region ${var.region} --body '{\"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"model\": \"${var.model_name}\"}' --content-type application/json output.json"
}
