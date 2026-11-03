terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name         = var.name
  variant_name = "AllTraffic"
  # Pin the model to an immutable image digest when one is supplied so that a
  # new push always rolls out a new SageMaker model.
  image_uri = var.image_digest != "" ? "${aws_ecr_repository.nim.repository_url}@${var.image_digest}" : "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR: SageMaker can only pull images from ECR, so the NIM image is mirrored here ---
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

# --- IAM: execution role assumed by the SageMaker endpoint ---
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

data "aws_iam_policy_document" "sagemaker_exec" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
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
    condition {
      test     = "StringLike"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/*"]
    }
  }
}

resource "aws_iam_role_policy" "sagemaker_exec" {
  name   = "sagemaker-exec"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker_exec.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  # Name is left to Terraform so the model can be replaced before the old one
  # is destroyed (the endpoint config references it).
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      # Needed by NIM to download model weights from NGC at startup.
      # NOTE: SageMaker stores container environment in plain text in the
      # model definition; restrict sagemaker:DescribeModel accordingly.
      NGC_API_KEY = var.ngc_api_key
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker_exec]

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = local.variant_name
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type # ml.g5.xlarge = 1x A10G (24GB VRAM)
    initial_instance_count = var.min_instances

    # TensorRT-LLM engine build + weight download on first boot takes minutes.
    container_startup_health_check_timeout_in_seconds = var.startup_health_check_timeout
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling: scale instance count on GPU utilization ---
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
    # GPUUtilization is published by SageMaker per instance (0-100 per GPU;
    # ml.g5.xlarge has a single GPU).
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

    target_value       = var.gpu_target_utilization # Scale out when GPU > 70% utilized
    scale_out_cooldown = 60                         # React fast to traffic spikes
    scale_in_cooldown  = 300                        # Cool down slowly to avoid cost churn
  }
}
