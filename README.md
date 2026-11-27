# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker InvokeEndpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                               └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                                                    ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, Secrets Manager, SageMaker model/endpoint, autoscaling) → Docker (NIM + SageMaker shim image)

| Previously (EKS) | Now (SageMaker) |
|------------------|-----------------|
| VPC + EKS cluster + GPU node group | Managed SageMaker endpoint (no cluster/VPC to run) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | `InvokeEndpoint` API (IAM-authenticated) |
| Readiness probe `/v1/health/ready` | SageMaker `/ping` → `/v1/health/ready` via Caddy shim |
| HPA on DCGM GPU util (Prometheus + adapter) | Application Auto Scaling on `GPUUtilization` |
| NGC pull secret / k8s secret | Image mirrored to ECR; NGC key in Secrets Manager |

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (x86_64 build host or buildx with `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances`
- ~$1.40/hr per `ml.g5.xlarge` endpoint instance (us-east-1 on-demand)

## Deploy

```bash
# Optional: customise instance type / scaling bounds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Creates ECR, builds + pushes the NIM image, deploys the endpoint (~15-25 min)
./scripts/deploy.sh <your-ngc-api-key>
```

`scripts/deploy.sh` wraps the NIM image with `sagemaker/` (a Caddy reverse proxy that
exposes SageMaker's `/ping` and `/invocations` contract on port 8080). `/invocations`
accepts an OpenAI-compatible chat completion body.

## Test it

```bash
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body file://request.json out.json && cat out.json
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 300
```

Watch instances scale:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region us-east-1
aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].CurrentInstanceCount'
```

Note: SageMaker publishes `GPUUtilization` at 1-minute granularity and new instances take
several minutes to become InService, so scale-out is slower than the EKS/HPA setup.

## Teardown

```bash
cd terraform && terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| GPU-aware autoscaling | `aws_appautoscaling_policy.gpu_util` | Scales on real GPU utilization, not CPU |
| SageMaker container contract | `sagemaker/` | Maps `/ping` + `/invocations` onto NIM's API |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
