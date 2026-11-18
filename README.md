# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This project previously ran on Amazon EKS (VPC + EKS node groups + DCGM/Prometheus + HPA).
> It now uses a fully managed SageMaker endpoint: no cluster, VPC, NAT gateway or
> metrics pipeline to operate.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → NIM container(s) on ml.g5.2xlarge (A10G GPU)
                                            ↑
                  Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (wrap NIM image for SageMaker, push to ECR)

| EKS (before) | SageMaker (now) |
|--------------|-----------------|
| VPC + EKS cluster + GPU node group | SageMaker endpoint (managed instances) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | SageMaker Runtime API (IAM-authenticated) |
| DCGM Exporter + Prometheus + Adapter + HPA | Built-in `GPUUtilization` metric + Application Auto Scaling |
| Image pulled from `nvcr.io` with pull secret | Image mirrored to ECR (SageMaker only pulls from ECR) |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Application Auto Scaling
- `terraform`, `docker` installed (x86_64 build host, or buildx with amd64 emulation)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.2xlarge for endpoint usage` (≥ `max_instances`)
- ~$1.50/hr budget per instance (one ml.g5.2xlarge on-demand)

## Deploy (~20 minutes)

```bash
# Optional: cp terraform/terraform.tfvars.example terraform/terraform.tfvars and edit

# 1. Create ECR repo, build + push the SageMaker NIM image, create the endpoint
./scripts/deploy.sh <your-ngc-api-key>

# 2. Test it
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

The request body is the standard OpenAI chat-completions payload; `/invocations` is proxied
to NIM's `/v1/chat/completions` (set `"stream": true` and use
`invoke-endpoint-with-response-stream` for token streaming).

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch instances scale (target tracking needs a few minutes of sustained load):

```bash
watch -n 30 aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

## Teardown

```bash
TF_VAR_ngc_api_key=unused terraform -chdir=terraform destroy
```

## Security notes

- The endpoint is not publicly reachable; callers need `sagemaker:InvokeEndpoint` IAM permission.
- `NGC_API_KEY` is set as a SageMaker model environment variable (NIM needs it to fetch weights),
  so it is visible to principals with `sagemaker:DescribeModel`. Restrict that permission, or
  pre-stage weights to avoid needing the key at runtime.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| SageMaker container contract | `sagemaker/` | Maps `/ping` + `/invocations` on :8080 to NIM's OpenAI API on :8000 |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
