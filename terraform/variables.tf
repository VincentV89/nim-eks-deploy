variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key used by NIM to download model weights"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the SageMaker-wrapped NIM image in ECR (pushed by scripts/deploy.sh). Must match [a-zA-Z0-9-]; it is part of the SageMaker model name."
  type        = string
  default     = "llama31-8b-instruct-1"
}

variable "instance_type" {
  type    = string
  default = "ml.g5.xlarge"
}

variable "min_instances" {
  type    = number
  default = 1
}

variable "max_instances" {
  type    = number
  default = 3
}

variable "gpu_target_utilization" {
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70
}
