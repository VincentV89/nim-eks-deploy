variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Name used for the ECR repo, SageMaker endpoint and related resources"
  type        = string
  default     = "nim-demo"
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key; NIM uses it to download model weights at startup"
  type        = string
  sensitive   = true
  default     = ""
}

variable "image_tag" {
  description = "Tag of the NIM SageMaker image pushed to ECR (see scripts/build_and_push.sh)"
  type        = string
  default     = "llama-3.1-8b-instruct-v1"
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
  description = "Target average GPU utilization (%) for the autoscaling policy"
  type        = number
  default     = 70
}
