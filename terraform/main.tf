terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile)
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # Remote, encrypted state. Terraform state contains the NGC API key, so it must
  # not live on a laptop. Partial configuration: supply bucket/key/region at init,
  # e.g. `terraform init -backend-config=backend.hcl` (see backend.hcl.example) —
  # scripts/deploy.sh does this from TF_STATE_BUCKET.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" { region = var.region }

locals {
  name      = "nim-demo"
  image_uri = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- KMS: customer-managed key for data at rest (ECR images, endpoint logs) ---
# Note: ml.g5 instances use NVMe instance storage, which SageMaker encrypts with
# a hardware module; SageMaker rejects a kms_key_arn on the endpoint config for
# instance types with local storage, so the key is not applied there.
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/Endpoints/${local.name}"]
    }
  }
}

resource "aws_kms_key" "nim" {
  description         = "${local.name} data-at-rest encryption"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "nim" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.nim.key_id
}

# --- CloudWatch Logs: endpoint container logs with retention + KMS ---
# Pre-created so logs are encrypted and expire instead of being kept forever.
resource "aws_cloudwatch_log_group" "endpoint" {
  name              = "/aws/sagemaker/Endpoints/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.nim.arn
}

# --- ECR: holds the NIM image (mirrored from nvcr.io + SageMaker shim) ---
# SageMaker can only pull from ECR, so scripts/deploy.sh pushes the image here.
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE" # deploy.sh pushes a unique tag per deploy
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.nim.arn
  }
}

# --- IAM execution role for the SageMaker model ---
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
  name_prefix        = "${local.name}-sm-"
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
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.nim.arn]
  }
  statement {
    sid       = "KmsDecryptImage"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.nim.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"]
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level permissions
    condition {
      test     = "StringLike"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/*"]
    }
  }
}

resource "aws_iam_role_policy" "sagemaker" {
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint config / endpoint ---
resource "aws_sagemaker_model" "nim" {
  # name omitted: Terraform generates a unique one so create_before_destroy works
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      # SageMaker has no native secret injection for container env vars. The key
      # is visible to principals with sagemaker:DescribeModel and is stored in
      # Terraform state — use an encrypted remote backend and scope IAM accordingly.
      NGC_API_KEY           = var.ngc_api_key
      NIM_SERVED_MODEL_NAME = var.model_name
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker]

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint_configuration" "nim" {
  name_prefix = "${local.name}-"

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.nim.name
    instance_type          = var.instance_type # ml.g5.xlarge = 1x A10G (24GB VRAM)
    initial_instance_count = var.min_instances

    # NIM downloads weights + builds the TensorRT-LLM engine on first boot.
    container_startup_health_check_timeout_in_seconds = 1800
    model_data_download_timeout_in_seconds            = 1800
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_sagemaker_endpoint" "nim" {
  name                 = local.name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim.name

  depends_on = [aws_cloudwatch_log_group.endpoint]
}

# --- Autoscaling: GPU-aware target tracking (replaces the EKS HPA + DCGM) ---
resource "aws_appautoscaling_target" "nim" {
  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.nim.name}/variant/AllTraffic"
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
    target_value       = var.gpu_target_utilization # scale up when GPU > 70%
    scale_out_cooldown = 60                         # react fast to traffic spikes
    scale_in_cooldown  = 300                        # cool down slowly to avoid churn

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
