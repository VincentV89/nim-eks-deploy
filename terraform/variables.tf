variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Tag of the SageMaker-ready NIM image in ECR (set by scripts/deploy.sh). null = no endpoint yet."
  type        = string
  default     = null
}

variable "served_model_name" {
  description = "Model name NIM serves; must match the `model` field in requests"
  type        = string
  default     = "meta/llama-3.1-8b-instruct"
}

variable "nim_start_cmd" {
  description = "Override for the NIM server start command inside the container (null = image default)"
  type        = string
  default     = null
}

variable "instance_type" {
  description = "SageMaker instance type (ml.g5.xlarge = 1x A10G, 24 GB VRAM)"
  type        = string
  default     = "ml.g5.xlarge"
}

variable "min_instances" {
  type    = number
  default = 1
  validation {
    condition     = var.min_instances >= 1
    error_message = "SageMaker real-time endpoints need at least one instance."
  }
}

variable "max_instances" {
  type    = number
  default = 3
  validation {
    condition     = var.max_instances >= var.min_instances
    error_message = "max_instances must be >= min_instances."
  }
}

variable "gpu_utilization_target" {
  description = "Average GPU utilization (%) the autoscaler keeps each instance at"
  type        = number
  default     = 70
  validation {
    condition     = var.gpu_utilization_target > 0 && var.gpu_utilization_target <= 100
    error_message = "gpu_utilization_target must be in (0, 100]."
  }
}
