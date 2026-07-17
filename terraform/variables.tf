variable "region" {
  description = "AWS region for SageMaker endpoint deployment"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "SageMaker instance type for the NIM endpoint"
  type        = string
  default     = "ml.g5.xlarge"
}

variable "initial_instance_count" {
  description = "Initial number of instances behind the SageMaker endpoint"
  type        = number
  default     = 1
}

variable "max_instance_count" {
  description = "Maximum number of instances for auto scaling"
  type        = number
  default     = 3
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key for pulling NIM model weights at runtime"
  type        = string
  sensitive   = true
}

variable "model_name" {
  description = "Short name for the model (used in resource naming)"
  type        = string
  default     = "llama-3-1-8b"
}

variable "nim_container_image" {
  description = "NIM container image URI"
  type        = string
  default     = "nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"
}
