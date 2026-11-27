terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

locals {
  name      = "nim-demo"
  image_uri = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR: SageMaker can only pull from ECR, so the NIM image (plus a small
# SageMaker shim) is mirrored here by scripts/deploy.sh ---
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

# --- NGC API key: NIM downloads model weights from NGC at startup ---
resource "aws_secretsmanager_secret" "ngc" {
  name                    = "${local.name}/ngc-api-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ngc" {
  secret_id     = aws_secretsmanager_secret.ngc.id
  secret_string = var.ngc_api_key
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
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.nim.arn]
  }
  statement {
    sid       = "ReadNgcKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ngc.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
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
  name   = "${local.name}-sagemaker"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint config / endpoint ---
resource "aws_sagemaker_model" "nim" {
  name               = local.name
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      # The shim's launch.sh resolves the key from Secrets Manager at boot, so
      # the raw key never appears in the SageMaker model definition.
      NGC_API_KEY_SECRET_ARN = aws_secretsmanager_secret.ngc.arn
      AWS_REGION             = var.region
      NIM_SERVED_MODEL_NAME  = var.model_name
    }
  }

  # Ensure the role can pull the image before SageMaker validates the model.
  depends_on = [aws_iam_role_policy.sagemaker]
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type # ml.g5.xlarge = 1x A10G (24GB VRAM)
    initial_instance_count = var.min_instances

    # TensorRT-LLM engine build + weight download can take several minutes.
    container_startup_health_check_timeout_in_seconds = 1800
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
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/AllTraffic"
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
    target_value       = var.gpu_target_utilization # Scale up when GPU > 70% utilized
    scale_out_cooldown = 30                         # React fast to traffic spikes
    scale_in_cooldown  = 300                        # Cool down slowly to avoid cost churn

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
