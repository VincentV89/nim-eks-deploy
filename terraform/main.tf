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

  # SageMaker models are immutable; derive a unique name from the inputs so a new
  # image or key creates a new model (create_before_destroy => zero-downtime swap).
  # The key is high-entropy, so a truncated hash of it is safe to expose.
  model_hash = substr(nonsensitive(sha256("${local.image_uri}|${var.ngc_api_key}")), 0, 12)
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR: SageMaker can only pull from ECR, so the NIM image is mirrored here ---
# (scripts/deploy.sh builds a thin SageMaker-compatible wrapper around the NGC
# image and pushes it to this repository before the endpoint is created.)
resource "aws_ecr_repository" "nim" {
  name                 = "${local.name}/llama-3.1-8b-instruct"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

# --- IAM execution role assumed by SageMaker hosting ---
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
  name               = "${local.name}-sagemaker-execution"
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
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "${local.name}-sagemaker-execution"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model: NIM container (Llama 3.1 8B Instruct) ---
resource "aws_sagemaker_model" "nim" {
  name               = "${local.name}-${local.model_hash}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    mode  = "SingleModel"
    environment = {
      # Used by NIM to download model weights from NGC at startup.
      NGC_API_KEY = var.ngc_api_key
    }
  }

  lifecycle { create_before_destroy = true }

  depends_on = [aws_iam_role_policy.sagemaker]
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = local.variant_name
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type
    initial_instance_count = var.min_instances

    # Weight download + TensorRT-LLM engine build can take several minutes.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling: replaces the K8s HPA on DCGM GPU utilization ---
resource "aws_appautoscaling_target" "nim" {
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/${local.variant_name}"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu_util" {
  name               = "${local.name}-gpu-utilization"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim.service_namespace
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.gpu_utilization_target
    scale_out_cooldown = 30  # React fast to traffic spikes
    scale_in_cooldown  = 300 # Cool down slowly to save cost churn

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
        value = local.variant_name
      }
    }
  }
}
