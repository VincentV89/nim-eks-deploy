variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key (used by NIM to download model weights)"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Immutable tag of the SageMaker-ready NIM image pushed to ECR by scripts/deploy.sh"
  type        = string

  validation {
    condition     = var.image_tag != "latest" && length(var.image_tag) > 0
    error_message = "image_tag must be a specific, immutable tag (not \"latest\")."
  }
}

variable "model_name" {
  type    = string
  default = "meta/llama-3.1-8b-instruct"
}

variable "instance_type" {
  type    = string
  default = "ml.g5.xlarge"
}

variable "min_instances" {
  type    = number
  default = 1

  validation {
    condition     = var.min_instances >= 1
    error_message = "min_instances must be at least 1 for a real-time endpoint."
  }
}

variable "max_instances" {
  description = "Autoscaling ceiling; must not exceed your ml.<type> endpoint-usage service quota"
  type        = number
  default     = 3

  validation {
    condition     = var.max_instances >= var.min_instances
    error_message = "max_instances must be >= min_instances."
  }
}

variable "gpu_target_utilization" {
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70

  validation {
    condition     = var.gpu_target_utilization > 0 && var.gpu_target_utilization <= 100
    error_message = "gpu_target_utilization must be in (0, 100]."
  }
}

variable "log_retention_days" {
  description = "Retention for the endpoint's CloudWatch log group"
  type        = number
  default     = 30
}
