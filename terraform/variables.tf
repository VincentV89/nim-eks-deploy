variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Tag of the NIM SageMaker image in the ECR repository (pushed by scripts/deploy.sh)"
  type        = string
  default     = "latest"
}

variable "instance_type" {
  description = "SageMaker instance type for the endpoint"
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

variable "gpu_target_utilization" {
  description = "Target average GPU utilization (%) for target-tracking autoscaling"
  type        = number
  default     = 70
}
