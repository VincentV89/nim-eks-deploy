variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Tag of the SageMaker NIM image in ECR. Empty = create only ECR/secret/IAM (stage 1). Set by scripts/deploy.sh via image.auto.tfvars."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "SageMaker instance type (ml.g5.xlarge = 1x A10G 24GB, same GPU as the former EKS g5.xlarge nodes)"
  type        = string
  default     = "ml.g5.xlarge"
}

variable "min_instances" {
  type    = number
  default = 1
  validation {
    condition     = var.min_instances >= 1
    error_message = "SageMaker real-time endpoints need at least 1 instance."
  }
}

variable "max_instances" {
  type    = number
  default = 3
}

variable "gpu_utilization_target" {
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70
}

variable "served_model_name" {
  description = "Model name NIM exposes (the `model` field in requests)"
  type        = string
  default     = "meta/llama-3.1-8b-instruct"
}
