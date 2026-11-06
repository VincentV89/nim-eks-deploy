variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key; NIM uses it to download model weights at startup. Pass via TF_VAR_ngc_api_key."
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the SageMaker-wrapped NIM image in ECR (pushed by scripts/deploy.sh)."
  type        = string
  default     = "latest"
}

variable "instance_type" {
  description = "SageMaker instance type. ml.g5.xlarge = 1x A10G (24GB VRAM)."
  type        = string
  default     = "ml.g5.xlarge"
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
  description = "Target average GPU utilization (%) for endpoint autoscaling."
  type        = number
  default     = 70
}
