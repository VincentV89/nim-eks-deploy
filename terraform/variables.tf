variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Name used for the ECR repository, SageMaker endpoint and related resources."
  type        = string
  default     = "nim-demo"
}

variable "instance_type" {
  description = "SageMaker instance type for the endpoint (ml.g5.xlarge = 1x A10G 24GB)."
  type        = string
  default     = "ml.g5.xlarge"
}

variable "min_instances" {
  description = "Minimum (and initial) number of endpoint instances."
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of endpoint instances the autoscaler may provision."
  type        = number
  default     = 3
}

variable "gpu_target_utilization" {
  description = "Target average GPU utilization (%) for target-tracking autoscaling."
  type        = number
  default     = 70
}

variable "startup_health_check_timeout" {
  description = "Seconds SageMaker waits for /ping to succeed after container start (max 3600)."
  type        = number
  default     = 1800
}

variable "image_tag" {
  description = "Tag of the NIM SageMaker image in ECR (used when image_digest is empty)."
  type        = string
  default     = "latest"
}

variable "image_digest" {
  description = "Optional immutable image digest (sha256:...) to deploy; set by scripts/deploy.sh."
  type        = string
  default     = ""
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key, used by NIM at runtime to download model weights."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ecr_force_delete" {
  description = "Allow `terraform destroy` to delete the ECR repository even if it contains images."
  type        = bool
  default     = true
}
