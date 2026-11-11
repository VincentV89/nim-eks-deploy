variable "region" {
  description = "AWS region for SageMaker endpoint deployment"
  type        = string
  default     = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key for accessing NIM container images"
  type        = string
  sensitive   = true
}

variable "sagemaker_instance_type" {
  description = "SageMaker instance type for the NIM endpoint"
  type        = string
  default     = "ml.g5.xlarge"
}

variable "min_instance_count" {
  description = "Minimum number of instances for the SageMaker endpoint"
  type        = number
  default     = 1
}

variable "max_instance_count" {
  description = "Maximum number of instances for the SageMaker endpoint autoscaling"
  type        = number
  default     = 3
}

variable "model_name" {
  description = "NIM model name identifier"
  type        = string
  default     = "nim-llama-3-1-8b"
}
