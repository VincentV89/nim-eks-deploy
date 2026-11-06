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

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR repository for the SageMaker-compatible NIM image ---
# SageMaker can only pull images from ECR, so the NGC image is mirrored here
# (with a thin /ping + /invocations shim) by scripts/deploy.sh.
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

# --- IAM execution role for SageMaker ---
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
  name               = "${local.name}-sagemaker-exec"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json
}

data "aws_iam_policy_document" "sagemaker_exec" {
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
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sagemaker_exec" {
  name   = "${local.name}-sagemaker-exec"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker_exec.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  name               = "${local.name}-${var.image_tag}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
    environment = {
      # NIM downloads optimized weights from NGC at startup.
      # NOTE: SageMaker model environment variables are visible via
      # DescribeModel; restrict sagemaker:DescribeModel accordingly.
      NGC_API_KEY = var.ngc_api_key
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker_exec]

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type # ml.g5.xlarge = 1x A10G (24GB VRAM)
    initial_instance_count = var.min_instances

    # NIM downloads weights and builds the TensorRT-LLM engine on first boot.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- GPU-aware autoscaling (replaces the Kubernetes HPA + DCGM/Prometheus stack) ---
resource "aws_appautoscaling_target" "nim" {
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/AllTraffic"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu_util" {
  name               = "${local.name}-gpu-util"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim.service_namespace
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.gpu_util_target # Scale up when GPU > 70% utilized
    scale_out_cooldown = 30                  # React fast to traffic spikes
    scale_in_cooldown  = 300                 # Cool down slowly to avoid cost churn

    # SageMaker publishes per-instance GPU utilization natively — no exporter needed.
    customized_metric_specification {
      metric_name = "GPUUtilization"
      namespace   = "/aws/sagemaker/Endpoints"
      statistic   = "Average"
      unit        = "Percent"

      dimensions {
        name  = "EndpointName"
        value = aws_sagemaker_endpoint.nim.name
      }
      dimensions {
        name  = "VariantName"
        value = "AllTraffic"
      }
    }
  }
}
