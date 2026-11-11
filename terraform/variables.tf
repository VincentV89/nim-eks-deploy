variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key — used by NIM to download model weights at startup"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the NIM SageMaker image pushed to ECR by scripts/deploy.sh"
  type        = string
  default     = "latest"
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

variable "gpu_util_target" {
  description = "Target average GPU utilization (%) per instance for autoscaling"
  type        = number
  default     = 70
}
