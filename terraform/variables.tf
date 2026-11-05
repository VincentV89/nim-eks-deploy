variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Tag of the SageMaker-compatible NIM image in ECR. scripts/deploy.sh pushes it and records it in image.auto.tfvars; there is deliberately no default so a manual apply cannot drift to a tag that was never pushed."
  type        = string
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

variable "gpu_util_target" {
  description = "Target average GPU utilization (%) for autoscaling."
  type        = number
  default     = 70
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for the ECR repository and the NGC secret. null = AWS-managed keys."
  type        = string
  default     = null
}

variable "ecr_force_delete" {
  description = "Allow `terraform destroy` to delete the ECR repository even if it still contains images."
  type        = bool
  default     = false
}

variable "subnet_ids" {
  description = "Optional private subnets for the endpoint. Empty = no VPC (SageMaker-managed networking)."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "Security groups for the endpoint when subnet_ids is set. Restrict egress to NGC and AWS endpoints."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.subnet_ids) == 0 || length(var.security_group_ids) > 0
    error_message = "security_group_ids is required when subnet_ids is set."
  }
}
