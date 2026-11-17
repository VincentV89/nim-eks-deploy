# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This repo previously deployed NIM on EKS (VPC + EKS cluster + k8s Deployment/Service/HPA + DCGM/Prometheus).
> It now uses a fully managed SageMaker endpoint — no cluster, nodes, VPC/NAT or metrics pipeline to run.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo-llm" → ml.g5.xlarge instance(s) (A10G GPU)
                                                                  └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                                                     ↑
                         Application Auto Scaling target-tracks the GPUUtilization CloudWatch metric
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (SageMaker-compatible NIM image)

| EKS (before) | SageMaker (now) |
|---|---|
| `terraform/` VPC + EKS + GPU node group | `terraform/` ECR + IAM role + SageMaker model/endpoint config/endpoint |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `sagemaker/` wrapper image |
| `k8s/nim-service.yaml` (public LoadBalancer) | SageMaker Runtime `InvokeEndpoint` (IAM-authenticated) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus Adapter | `aws_appautoscaling_policy` on built-in `GPUUtilization` |
| `ngc-secret` k8s secrets | `NGC_API_KEY` container env (sensitive TF variable) |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Application Auto Scaling
- `terraform` (>= 1.5), `docker`, Python 3 with `boto3`
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` (≥ `max_instances`)
- ~$1.41/hr budget (one ml.g5.xlarge endpoint instance, us-east-1 on-demand)

## Deploy

```bash
# Optional: tweak instance type / scaling bounds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Builds the image, pushes to ECR, creates the endpoint + autoscaling (~10-20 min)
./scripts/deploy.sh <your-ngc-api-key>

# Test it
ENDPOINT=$(terraform -chdir=terraform output -raw endpoint_name)
aws sagemaker-runtime invoke-endpoint --endpoint-name "$ENDPOINT" \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

`/invocations` accepts the same OpenAI chat-completions body that NIM's `/v1/chat/completions` does
(the routing shim lives in `sagemaker/Caddyfile`). Streaming (`"stream": true`) works via
`InvokeEndpointWithResponseStream`.

To redeploy a new NIM version, run `NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:<tag> ./scripts/deploy.sh <key>`;
each run pushes a new image tag, which creates a new model + endpoint config and performs a SageMaker rolling update.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py "$ENDPOINT" --region us-east-1 --rps 20 --duration 120
```

Watch instances scale:
`watch aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT" --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'`

## Teardown

```bash
TF_VAR_ngc_api_key=unused terraform -chdir=terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/` | Maps `/ping` + `/invocations` on :8080 onto NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
