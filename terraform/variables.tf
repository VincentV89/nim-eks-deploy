variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key — NIM uses it to download model weights at startup"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the NIM image pushed to ECR by scripts/deploy.sh"
  type        = string
  default     = "llama-3.1-8b-instruct"
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
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70
}
