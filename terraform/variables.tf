variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key used by NIM to download model weights at startup."
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Tag of the SageMaker-wrapped NIM image in ECR (pushed by scripts/deploy.sh)."
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
  description = "Target average GPU utilization (%) for endpoint autoscaling."
  type        = number
  default     = 70
}

variable "volume_size_gb" {
  description = "ML storage volume per instance for model weights and TensorRT engines."
  type        = number
  default     = 100
}
