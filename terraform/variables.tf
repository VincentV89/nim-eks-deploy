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
  description = "Tag of the SageMaker-ready NIM image pushed to ECR by scripts/deploy.sh"
  type        = string
  default     = "latest"
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
