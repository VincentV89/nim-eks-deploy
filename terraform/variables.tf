variable "region" {
  type    = string
  default = "us-east-1"
}

variable "ngc_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the NGC API key (created by scripts/deploy.sh)"
  type        = string
}

variable "image_tag" {
  description = "Tag of the SageMaker-adapted NIM image in ECR (pushed by scripts/deploy.sh)"
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

variable "gpu_target_utilization" {
  description = "Target average GPU utilization (%) for autoscaling"
  type        = number
  default     = 70
}
