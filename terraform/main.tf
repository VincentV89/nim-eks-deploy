terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name         = "nim-demo"
  variant_name = "AllTraffic"
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition

  # Stage 1 (no image yet): only ECR, secret and IAM are created.
  # Stage 2 (scripts/deploy.sh sets image_tag): model + endpoint + autoscaling.
  deploy_endpoint = var.image_tag != ""
  image_uri       = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

# --- Container registry (SageMaker can only pull from ECR) ---
resource "aws_ecr_repository" "nim" {
  name                 = "${local.name}-sagemaker"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo: allow `terraform destroy` with images present

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "nim" {
  repository = aws_ecr_repository.nim.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 5 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# --- NGC API key (value is written by scripts/deploy.sh, never stored in tfstate) ---
resource "aws_secretsmanager_secret" "ngc" {
  name_prefix             = "${local.name}/ngc-api-key-"
  description             = "NVIDIA NGC API key used by NIM to download model weights"
  recovery_window_in_days = 0 # demo: allow immediate re-create after destroy
}

# --- SageMaker execution role (least privilege) ---
data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
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
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.nim.arn]
  }
  statement {
    sid       = "NgcSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ngc.arn]
  }
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream",
      "logs:PutLogEvents", "logs:DescribeLogStreams",
    ]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/*"]
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
  name   = "nim-endpoint"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  count              = local.deploy_endpoint ? 1 : 0
  name               = "${local.name}-${replace(var.image_tag, "/[^a-zA-Z0-9-]/", "-")}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      NGC_API_KEY_SECRET_ID = aws_secretsmanager_secret.ngc.arn
      AWS_REGION            = var.region
      AWS_DEFAULT_REGION    = var.region
      NIM_SERVED_MODEL_NAME = var.served_model_name
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker]

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  count       = local.deploy_endpoint ? 1 : 0
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = local.variant_name
    model_name             = aws_sagemaker_model.nim[0].name
    instance_type          = var.instance_type
    initial_instance_count = var.min_instances

    # First boot downloads weights from NGC and builds/loads the TensorRT-LLM engine.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  count                = local.deploy_endpoint ? 1 : 0
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim[0].name
}

# --- Autoscaling (replaces the Kubernetes HPA on DCGM GPU utilization) ---
resource "aws_appautoscaling_target" "nim" {
  count              = local.deploy_endpoint ? 1 : 0
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim[0].name}/variant/${local.variant_name}"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu_util" {
  count              = local.deploy_endpoint ? 1 : 0
  name               = "${local.name}-gpu-utilization"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim[0].service_namespace
  resource_id        = aws_appautoscaling_target.nim[0].resource_id
  scalable_dimension = aws_appautoscaling_target.nim[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    # SageMaker reports GPUUtilization as 0-100 per GPU (ml.g5.xlarge has 1 GPU).
    target_value       = var.gpu_utilization_target
    scale_out_cooldown = 60  # react fast to traffic spikes
    scale_in_cooldown  = 300 # cool down slowly to avoid cost churn

    customized_metric_specification {
      metric_name = "GPUUtilization"
      namespace   = "/aws/sagemaker/Endpoints"
      statistic   = "Average"
      dimensions {
        name  = "EndpointName"
        value = aws_sagemaker_endpoint.nim[0].name
      }
      dimensions {
        name  = "VariantName"
        value = local.variant_name
      }
    }
  }
}
