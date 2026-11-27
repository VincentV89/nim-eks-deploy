variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key, used by NIM to download model weights. Pass via TF_VAR_ngc_api_key."
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the SageMaker-wrapped NIM image in ECR (set by scripts/deploy.sh). Use a unique tag per build so the endpoint rolls over."
  type        = string
  default     = "initial"

  validation {
    condition     = length(var.image_tag) <= 40
    error_message = "image_tag must be 40 characters or fewer (SageMaker model name limit is 63)."
  }
}

variable "instance_type" {
  type    = string
  default = "ml.g5.xlarge"
}

variable "min_instance_count" {
  type    = number
  default = 1
}

variable "max_instance_count" {
  type    = number
  default = 3

  validation {
    condition     = var.max_instance_count >= 1
    error_message = "max_instance_count must be at least 1."
  }
}

variable "gpu_target_utilization" {
  description = "Target average GPU utilisation (%) for autoscaling."
  type        = number
  default     = 70
}

variable "startup_health_check_timeout" {
  description = "Seconds SageMaker waits for /ping to succeed after container start."
  type        = number
  default     = 1800
}
