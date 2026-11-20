terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name = "nim-demo"
  # SageMaker models are immutable: embed the image tag in the model name so a
  # new image produces a new model + endpoint config and a rolling update.
  model_name = "${local.name}-${replace(var.image_tag, "/[^a-zA-Z0-9-]/", "-")}"
  image_uri  = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

data "aws_partition" "current" {}

# --- ECR ---
# SageMaker can only pull from ECR, so the NIM image (plus a small SageMaker
# shim, see container/) is mirrored from nvcr.io by scripts/deploy.sh.
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
  name_prefix        = "${local.name}-sm-"
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
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:*:log-group:/aws/sagemaker/*"]
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  name               = local.model_name
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      # SageMaker model environments do not support secret references, so the
      # key is passed as an env var (marked sensitive in Terraform). Rotate by
      # re-running `terraform apply` with a new TF_VAR_ngc_api_key.
      NGC_API_KEY = var.ngc_api_key
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker]

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name = local.model_name

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type
    initial_instance_count = var.min_instances

    # NIM downloads weights and builds/loads the TensorRT-LLM engine on boot.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling (replaces the EKS HPA + DCGM/Prometheus pipeline) ---
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
    target_value       = var.gpu_util_target # % GPU utilization (1 GPU per ml.g5.xlarge)
    scale_out_cooldown = 30                  # React fast to traffic spikes
    scale_in_cooldown  = 300                 # Cool down slowly to avoid cost churn

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
        value = "AllTraffic"
      }
    }
  }
}
