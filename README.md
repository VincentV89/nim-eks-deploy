# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client → SageMaker Runtime (InvokeEndpoint, SigV4) → ml.g5.xlarge instance(s) (A10G GPU)
                                                         └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                    ↑
   Application Auto Scaling target-tracks GPUUtilization (native CloudWatch metric)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (SageMaker wrapper image) → ECR

### What changed from the EKS version

| EKS (before) | SageMaker (now) |
|--------------|-----------------|
| VPC + EKS cluster + GPU node group | Managed SageMaker endpoint (`ml.g5.xlarge`) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + endpoint config (`terraform/main.tf`) |
| NGC image pull secret | NIM image mirrored to ECR (SageMaker only pulls from ECR) |
| Readiness probe `/v1/health/ready` | SageMaker `/ping` → `/v1/health/ready` (`docker/Caddyfile`) |
| `LoadBalancer` Service on :8000 | `InvokeEndpoint` → `/invocations` → `/v1/chat/completions` |
| HPA + DCGM exporter + Prometheus + adapter | Application Auto Scaling on `/aws/sagemaker/Endpoints` `GPUUtilization` |

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform` and `docker` installed (an x86_64 build host is recommended; the NIM image is ~15 GB)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free; needed to pull NIM images and model weights)
- `ml.g5.xlarge` endpoint quota in your region (Service Quotas → SageMaker)
- ~$1.41/hr budget per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional overrides
./scripts/deploy.sh <your-ngc-api-key>
```

The script creates the ECR repo, pulls NIM from `nvcr.io`, builds the SageMaker wrapper (`docker/`),
pushes it to ECR, and applies Terraform. `terraform apply` waits until the endpoint is `InService`;
the first boot downloads weights and builds the TensorRT engine (the startup health-check timeout is 30 min).

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install aiohttp boto3
python scripts/load_test.py --sagemaker-endpoint nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region us-east-1
aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].CurrentInstanceCount'
```

Target tracking runs on CloudWatch alarms at 1-minute resolution, so scale-out takes a few minutes
(plus instance boot), which is slower than the old HPA.

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## Security notes

- The NGC API key goes into the SageMaker model as a container environment variable (that's how NIM
  downloads weights). Anyone with `sagemaker:DescribeModel` can read it, and it is stored in Terraform
  state, so keep the state file private. For production, pre-package the weights in S3 or fetch the key
  from Secrets Manager inside the container.
- The endpoint is reachable only through IAM-authenticated `InvokeEndpoint` calls. There is no public
  load balancer anymore.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `docker/` | `/ping` + `/invocations` on :8080 mapped onto NIM's OpenAI API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
