# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker Endpoint → NIM container on ml.g5.xlarge (A10G GPU)
                        ↑
      Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (SageMaker-adapted NIM image)

The NIM image is wrapped by `container/` because SageMaker expects `GET /ping` and
`POST /invocations` on port 8080, while NIM serves an OpenAI-compatible API on port 8000.
`/invocations` is forwarded to `/v1/chat/completions`; `/ping` to `/v1/health/ready`.

### What changed vs. the EKS version

| EKS | SageMaker |
|-----|-----------|
| VPC + EKS cluster + GPU node group | Managed endpoint — no cluster, VPC, or NAT to run |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | `aws_sagemaker_endpoint` (IAM/SigV4-authenticated) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus + Adapter | Target-tracking policy on built-in `GPUUtilization` metric |
| NGC pull secret | Image mirrored to ECR by `scripts/deploy.sh` |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Application Auto Scaling
- `terraform`, `docker` installed (build host must be able to build `linux/amd64` images)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances`
- ~$1.40/hr per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # edit with your values
./scripts/deploy.sh <your-ngc-api-key>
```

The script creates the ECR repo, builds/pushes the image, then creates the endpoint and
autoscaling. Endpoint creation waits until the NIM container is healthy (weight download +
TensorRT engine build), which typically takes 10–20 minutes.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 300
```

Watch scaling:
`aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region us-east-1`

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| SageMaker container contract | `container/` | Bridges `/ping` + `/invocations` to NIM's OpenAI API |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
