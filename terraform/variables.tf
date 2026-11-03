variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Tag of the SageMaker-wrapped NIM image in ECR (pushed by scripts/deploy.sh)"
  type        = string
  default     = "latest"
}

variable "served_model_name" {
  description = "Model name NIM serves (the `model` field in chat completion requests)"
  type        = string
  default     = "meta/llama-3.1-8b-instruct"
}

variable "instance_type" {
  description = "SageMaker hosting instance type (ml.g5.xlarge = 1x A10G, 24GB VRAM)"
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
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70
}

variable "startup_timeout_seconds" {
  description = "Time allowed for NIM to download weights and pass its first health check"
  type        = number
  default     = 1800
}
