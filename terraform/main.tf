terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name         = "nim-demo"
  variant_name = "AllTraffic"
  image_uri    = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

data "aws_partition" "current" {}

# --- Container registry ---
# SageMaker can only pull hosting images from ECR, so the NIM image (plus the
# SageMaker shim in sagemaker/) is re-built and pushed here by scripts/deploy.sh.
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

# --- NGC API key ---
# Only the secret container is managed here; the value is written out-of-band by
# scripts/deploy.sh so the key never lands in Terraform state.
resource "aws_secretsmanager_secret" "ngc_api_key" {
  name_prefix             = "${local.name}-ngc-api-key-"
  description             = "NVIDIA NGC API key used by NIM to download model weights"
  recovery_window_in_days = 0
}

# --- SageMaker execution role ---
data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name_prefix        = "${local.name}-sagemaker-"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json
}

data "aws_iam_policy_document" "sagemaker" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.nim.arn]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:*:*:log-group:/aws/sagemaker/*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid       = "NgcSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ngc_api_key.arn]
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "${local.name}-sagemaker"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
# The model has no fixed name so that changing the image tag creates a new model,
# and the endpoint config uses name_prefix + create_before_destroy so the endpoint
# is updated in place (blue/green) instead of being torn down.
resource "aws_sagemaker_model" "nim" {
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      NGC_API_KEY_SECRET_ID = aws_secretsmanager_secret.ngc_api_key.arn
      NIM_SERVED_MODEL_NAME = var.served_model_name
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker]
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = local.variant_name
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type
    initial_instance_count = var.min_instances

    # NIM downloads weights and builds/loads the TensorRT-LLM engine on first
    # boot, which can take several minutes.
    container_startup_health_check_timeout_in_seconds = var.startup_timeout_seconds
    model_data_download_timeout_in_seconds            = var.startup_timeout_seconds
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling (replaces the Kubernetes HPA on DCGM GPU utilization) ---
resource "aws_appautoscaling_target" "nim" {
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/${local.variant_name}"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu_utilization" {
  name               = "${local.name}-gpu-utilization"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim.service_namespace
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension

  target_tracking_scaling_policy_configuration {
    # GPUUtilization is reported per instance as 0-100 x number of GPUs;
    # ml.g5.xlarge has a single A10G, so this is a plain percentage.
    target_value       = var.gpu_utilization_target
    scale_out_cooldown = 60  # React fast to traffic spikes
    scale_in_cooldown  = 300 # Cool down slowly to save cost churn

    customized_metric_specification {
      metric_name = "GPUUtilization"
      namespace   = "/aws/sagemaker/Endpoints"
      statistic   = "Average"

      dimensions {
        name  = "EndpointName"
        value = aws_sagemaker_endpoint.nim.name
      }
      dimensions {
        name  = "VariantName"
        value = local.variant_name
      }
    }
  }
}
