terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name = "nim-demo"
}

# --- IAM Role for SageMaker ---
resource "aws_iam_role" "sagemaker_execution" {
  name = "${local.name}-sagemaker-execution-role"

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

resource "aws_iam_role_policy" "sagemaker_scoped" {
  name = "${local.name}-sagemaker-scoped"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SageMakerModelEndpoint"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateModel",
          "sagemaker:DescribeModel",
          "sagemaker:DeleteModel",
          "sagemaker:CreateEndpointConfig",
          "sagemaker:DescribeEndpointConfig",
          "sagemaker:DeleteEndpointConfig",
          "sagemaker:CreateEndpoint",
          "sagemaker:DescribeEndpoint",
          "sagemaker:DeleteEndpoint",
          "sagemaker:UpdateEndpoint",
          "sagemaker:InvokeEndpoint",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRImagePull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:*:*:log-group:/aws/sagemaker/*"
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "/aws/sagemaker/Endpoints"
          }
        }
      },
      {
        Sid    = "VPCNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

# --- SageMaker Model ---
resource "aws_sagemaker_model" "nim" {
  name               = local.name
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    # For production, pin to a specific image digest (e.g., nvcr.io/nim/meta/llama-3.1-8b-instruct@sha256:...)
    # to ensure reproducible deployments.
    image = "nvcr.io/nim/meta/llama-3.1-8b-instruct:latest"

    # NOTE: NGC_API_KEY will be stored in Terraform state in plaintext because
    # the SageMaker model resource requires environment variables directly.
    # Use a remote backend with encryption (e.g., S3 with SSE) to protect state.
    environment = {
      NGC_API_KEY   = var.ngc_api_key
      NIM_MODEL_NAME = var.model_name
    }

    container_hostname = local.name
  }
}

# --- SageMaker Endpoint Configuration ---
resource "aws_sagemaker_endpoint_configuration" "nim" {
  name = "${local.name}-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.nim.name
    initial_instance_count = var.min_instance_count
    instance_type          = var.sagemaker_instance_type
    container_startup_health_check_timeout_in_seconds = 600
  }
}

# --- SageMaker Endpoint ---
resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling ---
resource "aws_appautoscaling_target" "nim" {
  max_capacity       = var.max_instance_count
  min_capacity       = var.min_instance_count
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/primary"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"
}

resource "aws_appautoscaling_policy" "nim" {
  name               = "${local.name}-invocations-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension
  service_namespace  = aws_appautoscaling_target.nim.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }

    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
