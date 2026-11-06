# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker endpoint → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                            ↑
               Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (SageMaker adapter for NIM)

Inside each instance, `container/launch.sh` starts NIM on `:8000` and a Caddy proxy on `:8080` that maps the
SageMaker hosting contract onto NIM's OpenAI-compatible API:

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` |

### What changed from the EKS version

| EKS | SageMaker |
|-----|-----------|
| VPC + NAT + EKS cluster + GPU node group | Managed SageMaker endpoint (no cluster/VPC to run) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | `aws_sagemaker_endpoint` (IAM/SigV4-authenticated) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus + Adapter | `aws_appautoscaling_policy` on built-in `GPUUtilization` |
| Image pulled from `nvcr.io` with a K8s pull secret | Image mirrored to ECR; NGC key read from Secrets Manager at boot |

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (image is built for `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for at least 1 (up to 3) `ml.g5.xlarge for endpoint usage`
- ~$1.50/hr per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy (~20 minutes)

```bash
# 1. Build/push the image and create the endpoint (blocks until InService)
export NGC_API_KEY=<your-ngc-api-key>
./scripts/deploy.sh

# 2. Test it
./scripts/invoke.sh nim-demo "Hello"
```

`deploy.sh` stores the NGC key in Secrets Manager (`nim-demo/ngc-api-key`) and passes only the secret ARN to
Terraform, so the key never lands in Terraform state or in the SageMaker model definition.
Override defaults with `AWS_REGION`, `NIM_IMAGE`, `IMAGE_TAG` or `NGC_SECRET_NAME`; other knobs
(instance type, min/max instances, GPU target) live in `terraform/variables.tf` — see `terraform.tfvars.example`.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600
```

Watch instances scale (target tracking acts on CloudWatch alarms, so expect a few minutes of lag):

```bash
watch -n 30 "aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

## Teardown

```bash
SECRET_ARN=$(aws secretsmanager describe-secret --secret-id nim-demo/ngc-api-key --query ARN --output text)
cd terraform && terraform destroy -var "ngc_secret_arn=$SECRET_ARN"
aws secretsmanager delete-secret --secret-id nim-demo/ngc-api-key --force-delete-without-recovery
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `container/` | `/ping` + `/invocations` on `:8080` adapted onto NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
