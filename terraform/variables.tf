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
  description = "Tag of the SageMaker-wrapped NIM image pushed to ECR by scripts/deploy.sh."
  type        = string
  default     = "latest"
}

variable "instance_type" {
  type    = string
  default = "ml.g5.xlarge"
}

variable "volume_size_gb" {
  description = "Instance storage for model weights and the TensorRT engine cache."
  type        = number
  default     = 100
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
  description = "Target average GPU utilization (%) for autoscaling."
  type        = number
  default     = 70
}
