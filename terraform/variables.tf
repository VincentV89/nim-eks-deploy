variable "region" {
  description = "AWS region for SageMaker endpoint deployment"
  type        = string
  default     = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key for pulling NIM container images"
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "SageMaker instance type for inference"
  type        = string
  default     = "ml.g5.xlarge"
}

variable "initial_instance_count" {
  description = "Initial number of instances for the endpoint"
  type        = number
  default     = 1
}

variable "max_instance_count" {
  description = "Maximum number of instances for auto scaling"
  type        = number
  default     = 3
}

variable "model_name" {
  description = "NVIDIA NIM model name"
  type        = string
  default     = "meta/llama-3.1-8b-instruct"
}
