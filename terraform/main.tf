terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name = "nim-llama-3-1-8b"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- IAM Role for SageMaker Execution ---
resource "aws_iam_role" "sagemaker_execution" {
  name = "${local.name}-sagemaker-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "sagemaker_execution" {
  name = "${local.name}-sagemaker-policy"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateModel",
          "sagemaker:CreateEndpointConfig",
          "sagemaker:CreateEndpoint",
          "sagemaker:InvokeEndpoint"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- SageMaker Model ---
resource "aws_sagemaker_model" "nim" {
  name               = local.name
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    image = "nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"

    environment = {
      NGC_API_KEY = var.ngc_api_key
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
    target_value = 5.0

    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
