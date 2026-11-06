terraform {
  required_version = ">= 1.9" # cross-variable validation
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

provider "aws" { region = var.region }

locals {
  name       = "nim-demo"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  image_uri  = "${aws_ecr_repository.nim.repository_url}:${coalesce(var.image_tag, "none")}"

  # The endpoint is only created once scripts/deploy.sh has pushed an image and passes
  # its tag; the first apply without a tag just creates the ECR repo, secret and role.
  endpoint_count = var.image_tag == null ? 0 : 1

  # SageMaker model names must be unique and models are immutable, so any change to
  # the container definition gets a new name (create_before_destroy below).
  model_config_hash = substr(sha1(jsonencode({
    image             = local.image_uri
    served_model_name = var.served_model_name
    nim_start_cmd     = var.nim_start_cmd
  })), 0, 12)
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- Container registry (NIM image + SageMaker shim, pushed by scripts/deploy.sh) ---
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo convenience: lets `terraform destroy` remove pushed images

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "nim" {
  repository = aws_ecr_repository.nim.name
  # Only untagged layers are expired, so the image a live endpoint uses is never removed.
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

# --- NGC API key ---
# Terraform only creates the secret container; scripts/deploy.sh writes the value, so
# the key never lands in Terraform state or in the SageMaker model definition.
resource "aws_secretsmanager_secret" "ngc" {
  name                    = "${local.name}/ngc-api-key"
  description             = "NVIDIA NGC API key used by NIM to download model weights"
  recovery_window_in_days = 0 # demo convenience: allows immediate re-create after destroy
}

# --- IAM execution role for the SageMaker endpoint ---
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
  name   = "${local.name}-sagemaker-execution"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  count = local.endpoint_count

  name               = "${local.name}-${local.model_config_hash}"
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = merge(
      {
        NGC_SECRET_ID         = aws_secretsmanager_secret.ngc.arn
        NIM_SERVED_MODEL_NAME = var.served_model_name
      },
      var.nim_start_cmd == null ? {} : { NIM_START_CMD = var.nim_start_cmd },
    )
  }

  lifecycle { create_before_destroy = true }

  depends_on = [aws_iam_role_policy.sagemaker]
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  count = local.endpoint_count

  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.nim[0].name
    instance_type          = var.instance_type
    initial_instance_count = var.min_instances

    # First boot downloads ~16 GB of weights from NGC and builds/loads the TensorRT-LLM
    # engine; /ping only returns 200 once NIM is ready.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  count = local.endpoint_count

  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim[0].name
}

# --- Autoscaling: GPU utilization target tracking (replaces the EKS HPA + DCGM stack) ---
resource "aws_appautoscaling_target" "nim" {
  count = local.endpoint_count

  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim[0].name}/variant/AllTraffic"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_instances
  max_capacity       = var.max_instances
}

resource "aws_appautoscaling_policy" "gpu_utilization" {
  count = local.endpoint_count

  name               = "${local.name}-gpu-utilization"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.nim[0].service_namespace
  resource_id        = aws_appautoscaling_target.nim[0].resource_id
  scalable_dimension = aws_appautoscaling_target.nim[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.gpu_utilization_target
    scale_out_cooldown = 300 # new GPU instances take minutes to pass /ping
    scale_in_cooldown  = 600 # scale in slowly to avoid churn

    # GPUUtilization is the per-instance sum across GPUs (0-100 per GPU); ml.g5.xlarge
    # has one A10G, so the target maps directly to percent utilization.
    customized_metric_specification {
      metric_name = "GPUUtilization"
      namespace   = "/aws/sagemaker/Endpoints"
      statistic   = "Average"
      unit        = "Percent"

      dimensions {
        name  = "EndpointName"
        value = aws_sagemaker_endpoint.nim[0].name
      }
      dimensions {
        name  = "VariantName"
        value = "AllTraffic"
      }
    }
  }
}
