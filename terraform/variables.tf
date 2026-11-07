variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key (stored in Secrets Manager; used by NIM to download model weights)"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the SageMaker-compatible NIM image in ECR (pushed by scripts/deploy.sh)"
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

variable "gpu_utilization_target" {
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70
}
