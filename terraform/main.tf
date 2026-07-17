terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name = "nim-${var.model_name}"
}

# --- IAM Role for SageMaker ---
data "aws_iam_policy_document" "sagemaker_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker_execution" {
  name               = "${local.name}-sagemaker-execution"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume_role.json
}

resource "aws_iam_role_policy_attachment" "sagemaker_full_access" {
  role       = aws_iam_role.sagemaker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.sagemaker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# --- SageMaker Model ---
resource "aws_sagemaker_model" "nim" {
  name               = local.name
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    image = var.nim_container_image
    environment = {
      NGC_API_KEY           = var.ngc_api_key
      NIM_SERVER_PORT       = "8080"
      NIM_MODEL_NAME        = "meta/llama-3.1-8b-instruct"
    }
  }
}

# --- SageMaker Endpoint Configuration ---
resource "aws_sagemaker_endpoint_configuration" "nim" {
  name = "${local.name}-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type
    initial_instance_count = var.initial_instance_count
    container_startup_health_check_timeout_in_seconds = 600
  }
}

# --- SageMaker Endpoint ---
resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Application Auto Scaling ---
resource "aws_appautoscaling_target" "nim" {
  max_capacity       = var.max_instance_count
  min_capacity       = var.initial_instance_count
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/primary"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"
}

resource "aws_appautoscaling_policy" "nim" {
  name               = "${local.name}-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension
  service_namespace  = aws_appautoscaling_target.nim.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }
    target_value       = 100.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
