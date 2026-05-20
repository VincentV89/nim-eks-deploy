terraform {
  # NOTE: The NGC API key is stored in Terraform state as part of the SageMaker model
  # environment configuration. Use a remote backend with encryption (e.g., S3 with
  # server-side encryption and restricted access) to protect sensitive values at rest.
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name      = "nim-llama-3-1-8b"
  ecr_image = "${aws_ecr_repository.nim.repository_url}:latest"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR Repository ---
# SageMaker cannot pull from nvcr.io (NGC private registry) directly.
# The NIM container image must be pushed to this ECR repository before deploying.
# See scripts/deploy.sh for the automated pull-tag-push workflow.
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

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
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        # GetAuthorizationToken does not support resource-level permissions
        Resource = "*"
      },
      {
        Sid    = "ECRPullFromNIMRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = aws_ecr_repository.nim.arn
      },
      {
        Sid    = "S3ModelArtifacts"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        # Model artifacts bucket - scope further if you use a dedicated bucket
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# --- SageMaker Model ---
resource "aws_sagemaker_model" "nim" {
  name               = local.name
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    image = local.ecr_image

    # WARNING: NGC_API_KEY will be stored in Terraform state in plaintext.
    # Ensure your state backend is encrypted and access-controlled.
    # Consider AWS Secrets Manager for production deployments.
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
    # SageMakerVariantInvocationsPerInstance counts invocations per minute per instance.
    # For LLM inference on ml.g5.xlarge (A10G) where each request takes 2-10 seconds,
    # 60 invocations/min/instance is a reasonable threshold before scaling out.
    target_value = 60.0

    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
