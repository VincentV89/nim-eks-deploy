variable "region" {
  description = "AWS region for SageMaker deployment"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for resource names (allows parallel deployments in the same account)"
  type        = string
  default     = "nim-demo"
}

variable "nim_image_uri" {
  description = "NVIDIA NIM container image URI"
  type        = string
  default     = "nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"
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
  description = "Maximum number of instances for auto-scaling"
  type        = number
  default     = 3
}

variable "ngc_api_key" {
  description = "NGC API key for pulling the NIM model"
  type        = string
  sensitive   = true
}

variable "scaling_target_value" {
  description = "Target invocations per instance for auto-scaling"
  type        = number
  default     = 70
}
