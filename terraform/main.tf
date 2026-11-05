terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # State is local by default. For anything long-lived, copy backend.tf.example
  # to backend.tf to use an encrypted, locked S3 backend.
}

provider "aws" { region = var.region }

locals {
  name = "nim-demo"
  # SageMaker cannot pull from nvcr.io directly, so the NIM image (plus a small
  # SageMaker compatibility shim, see sagemaker/Dockerfile) is mirrored into ECR.
  image_uri = "${aws_ecr_repository.nim.repository_url}:${var.image_tag}"

  log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/Endpoints/${local.name}"
  use_vpc       = length(var.subnet_ids) > 0
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- ECR: holds the SageMaker-compatible NIM image ---
resource "aws_ecr_repository" "nim" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE"
  # Default false: `terraform destroy` refuses to delete a repo that still has
  # images. Set ecr_force_delete = true for throwaway demo environments.
  force_delete = var.ecr_force_delete

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn # null = AWS-managed aws/ecr key
  }
}

# --- NGC API key: Secrets Manager (value is set by scripts/deploy.sh) ---
# Terraform only creates the secret *container*. deploy.sh writes the value with
# `aws secretsmanager put-secret-value`, so the key never enters Terraform state
# or the SageMaker model definition (DescribeModel only shows the secret ARN).
resource "aws_secretsmanager_secret" "ngc" {
  name_prefix = "${local.name}-ngc-api-key-"
  description = "NVIDIA NGC API key used by the NIM container to download model weights."
  kms_key_id  = var.kms_key_arn # null = AWS-managed aws/secretsmanager key
}

# --- IAM execution role for the SageMaker endpoint ---
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
    sid       = "NgcSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ngc.arn]
  }

  # Only this endpoint's log group (SageMaker writes to /aws/sagemaker/Endpoints/<name>).
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [local.log_group_arn, "${local.log_group_arn}:*"]
  }

  # Customer-managed KMS key (optional) for the ECR image and the NGC secret.
  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]
    content {
      sid       = "Kms"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }

  # ENI management, only when the endpoint runs inside a VPC.
  dynamic "statement" {
    for_each = local.use_vpc ? [1] : []
    content {
      sid = "VpcEni"
      actions = [
        "ec2:CreateNetworkInterface",
        "ec2:CreateNetworkInterfacePermission",
        "ec2:DeleteNetworkInterface",
        "ec2:DeleteNetworkInterfacePermission",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeVpcs",
        "ec2:DescribeDhcpOptions",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
      ]
      resources = ["*"]
    }
  }
  # No cloudwatch:PutMetricData: SageMaker publishes GPUUtilization and
  # invocation metrics itself, not through the execution role.
}

resource "aws_iam_role_policy" "sagemaker" {
  name   = "${local.name}-sagemaker"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker.json
}

# --- SageMaker model / endpoint ---
resource "aws_sagemaker_model" "nim" {
  # No explicit name: Terraform generates a unique one, so create_before_destroy
  # never collides with the model it is replacing (SageMaker models are immutable).
  execution_role_arn = aws_iam_role.sagemaker.arn

  primary_container {
    image = local.image_uri
    environment = {
      # launch.sh fetches the key from Secrets Manager at startup.
      NGC_SECRET_ARN = aws_secretsmanager_secret.ngc.arn
      AWS_REGION     = var.region
    }
  }

  # Optional private networking. Egress must still reach NGC
  # (e.g. NAT + egress allow-list for *.ngc.nvidia.com, *.nvcr.io) and
  # Secrets Manager (NAT or a VPC interface endpoint).
  dynamic "vpc_config" {
    for_each = local.use_vpc ? [1] : []
    content {
      subnets            = var.subnet_ids
      security_group_ids = var.security_group_ids
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

# --- GPU-aware autoscaling (replaces the Kubernetes HPA + DCGM/Prometheus stack) ---
# NOTE: changing instance_type on an autoscaled variant requires deregistering
# the scalable target first (see README "Updating the endpoint").
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
    # SageMaker publishes per-instance GPUUtilization natively (0-100 per GPU;
    # ml.g5.xlarge has one A10G so 0-100 overall).
    target_value       = var.gpu_util_target
    scale_out_cooldown = 60  # react fast to traffic spikes
    scale_in_cooldown  = 300 # cool down slowly to avoid cost churn

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
