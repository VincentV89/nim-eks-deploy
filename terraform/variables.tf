variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  description = "SageMaker instance type for the endpoint (requires the matching 'for endpoint usage' service quota)."
  type        = string
  default     = "ml.g5.xlarge"
}

variable "min_instances" {
  description = "Minimum (and initial) number of endpoint instances."
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of endpoint instances for autoscaling."
  type        = number
  default     = 3
}

variable "gpu_target_utilization" {
  description = "Target average GPU utilization (%) for target-tracking autoscaling."
  type        = number
  default     = 70
}

variable "container_startup_timeout" {
  description = "Seconds SageMaker waits for /ping to succeed (NIM model download + engine build)."
  type        = number
  default     = 1800
}

variable "nim_image_tag" {
  description = "Tag of the NIM SageMaker image pushed to ECR by scripts/deploy.sh."
  type        = string
  default     = "latest"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key; NIM uses it to download model weights. Pass via TF_VAR_ngc_api_key."
  type        = string
  sensitive   = true
}
