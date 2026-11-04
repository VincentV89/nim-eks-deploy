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
  image_uri    = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR: SageMaker can only pull images from ECR, so the NIM image is
#     mirrored here (with a small SageMaker shim) by scripts/deploy.sh ---
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

# --- NGC API key: kept in Secrets Manager (encrypted at rest) instead of
#     tfvars/state-adjacent plaintext where possible ---
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
  name               = "${local.name}-sagemaker-exec"
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
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"
    ]
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
  statement {
    sid       = "NgcSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ngc.arn]
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "${local.name}-sagemaker-exec"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  name               = "${local.name}-${substr(sha1(local.image_uri), 0, 8)}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      # The shim (sagemaker/launch.sh) resolves the NGC key from Secrets
      # Manager at startup so it never appears in the model definition.
      NGC_API_KEY_SECRET_ARN = aws_secretsmanager_secret.ngc.arn
      AWS_REGION             = var.region
      NIM_SERVED_MODEL_NAME  = var.model_name
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker]

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = local.variant_name
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type # ml.g5.xlarge = 1x A10G (24GB VRAM)
    initial_instance_count = var.min_instances

    # NIM downloads weights from NGC and builds the TensorRT-LLM engine on
    # first boot, which can take several minutes.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name
}

# --- Autoscaling: GPU-utilization target tracking (replaces the EKS HPA +
#     DCGM exporter + Prometheus adapter pipeline) ---
resource "aws_appautoscaling_target" "nim" {
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/${local.variant_name}"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu" {
  name               = "${local.name}-gpu-util"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim.service_namespace
  resource_id        = aws_appautoscaling_target.nim.resource_id
  scalable_dimension = aws_appautoscaling_target.nim.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.gpu_target_utilization
    scale_out_cooldown = 60  # React fast to traffic spikes
    scale_in_cooldown  = 300 # Cool down slowly to avoid cost churn

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
