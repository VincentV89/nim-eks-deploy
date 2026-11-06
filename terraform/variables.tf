variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key. NIM uses it to download model weights at startup."
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the SageMaker-adapted NIM image pushed to ECR by scripts/deploy.sh."
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

variable "gpu_utilization_target" {
  description = "Average GPU utilization (%) the endpoint autoscaler tracks."
  type        = number
  default     = 70
}
