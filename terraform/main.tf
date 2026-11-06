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

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR ---
# SageMaker can only pull images from ECR, so the NIM image (plus a thin
# SageMaker adapter layer, see container/) is mirrored here by scripts/deploy.sh.
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

# --- IAM execution role for the SageMaker endpoint ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name               = "${local.name}-sagemaker-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
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
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/*"]
    }
  }

  # The NGC API key is read at container start (container/launch.sh) so it
  # never appears in the SageMaker model definition or in Terraform state.
  statement {
    sid       = "NgcSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.ngc_secret_arn]
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "${local.name}-sagemaker"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  # Name derived from the image tag so a new image forces a new model and a
  # blue/green endpoint update instead of an in-place failure.
  name               = "${local.name}-${replace(var.image_tag, "/[^a-zA-Z0-9-]/", "-")}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      NGC_API_KEY_SECRET_ARN = var.ngc_secret_arn
      AWS_REGION             = var.region
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker]
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = local.variant_name
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type # ml.g5.xlarge = 1x A10G (24GB VRAM)
    initial_instance_count = var.min_instances

    # First boot pulls weights from NGC and builds the TensorRT-LLM engine.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling (replaces the Kubernetes HPA + DCGM/Prometheus pipeline) ---
resource "aws_appautoscaling_target" "nim" {
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/${local.variant_name}"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu" {
  name               = "${local.name}-gpu-utilization"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim.service_namespace
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension

  target_tracking_scaling_policy_configuration {
    # SageMaker publishes GPUUtilization natively (no DCGM exporter needed).
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

    target_value       = var.gpu_target_utilization # scale out when GPU > 70%
    scale_out_cooldown = 60                         # react fast to traffic spikes
    scale_in_cooldown  = 300                        # cool down slowly to avoid churn
  }
}
