# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This project previously ran NIM on EKS (Deployment + LoadBalancer Service + DCGM/Prometheus-driven HPA).
> It now uses a managed SageMaker endpoint — no cluster, node groups, VPC/NAT or metrics pipeline to run.

## Architecture

```
Client ──SigV4──▶ SageMaker InvokeEndpoint ──▶ ml.g5.xlarge instance(s) (A10G GPU)
                                                  └─ container: Caddy :8080 ──▶ NIM :8000
                                                       /ping        → /v1/health/ready
                                                       /invocations → /v1/chat/completions
                         ↑
   Application Auto Scaling target-tracks CloudWatch GPUUtilization
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (wrap NIM image for SageMaker) → ECR

| EKS (before)                              | SageMaker (now)                                        |
|-------------------------------------------|--------------------------------------------------------|
| VPC + EKS cluster + GPU node group        | `aws_sagemaker_endpoint` on `ml.g5.xlarge`             |
| `k8s/nim-deployment.yaml` (pulls nvcr.io) | NIM image mirrored to ECR, wrapped by `sagemaker/`     |
| `k8s/nim-service.yaml` (public NLB)       | IAM-authenticated `InvokeEndpoint` (no public port)    |
| Readiness probe `/v1/health/ready`        | SageMaker `/ping` → `/v1/health/ready`                 |
| HPA on DCGM GPU util via Prometheus       | Application Auto Scaling on `GPUUtilization` (70%)     |
| NGC key in Kubernetes Secret              | NGC key as a sensitive Terraform var → model env       |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM and Application Auto Scaling
- `terraform`, `docker` installed (x86_64 build; on Apple Silicon/ARM, Docker uses emulation)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instance_count` (default 3)
- ~$1.40/hr per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy (~20 minutes)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional: edit sizes/region
./scripts/deploy.sh <your-ngc-api-key>
```

`deploy.sh` creates the ECR repository, builds `sagemaker/Dockerfile` on top of the NIM image,
pushes it to ECR with a unique tag, and applies the rest of the Terraform (model, endpoint
config, endpoint, autoscaling). Re-running it builds a new tag and rolls the endpoint over.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker
aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].CurrentInstanceCount'
```

SageMaker GPU metrics arrive in CloudWatch at 1-minute granularity and new instances take several
minutes to boot NIM, so run the load test for ≥10 minutes to see a scale-out.

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
| SageMaker container contract | `sagemaker/Caddyfile` | Maps `/ping` + `/invocations` on :8080 to NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not invocations/CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
