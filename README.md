# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> Previously this repo deployed NIM on EKS (VPC + EKS + DCGM/Prometheus/HPA). The inference
> deployment now runs on a fully managed SageMaker endpoint — no cluster, node groups,
> or metrics pipeline to operate.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → ml.g5.xlarge instance(s) (A10G GPU)
                                                              └─ container: Caddy :8080 → NIM :8000
                                       ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch, 70%)
```

**Stack:** Terraform (ECR, IAM, Secrets Manager, SageMaker, autoscaling) → Docker (SageMaker-compatible NIM image)

| EKS (before) | SageMaker (now) |
|---|---|
| VPC + EKS cluster + GPU node group (`g5.xlarge`) | SageMaker endpoint on `ml.g5.xlarge` |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `container/` shim |
| `k8s/nim-service.yaml` (public LoadBalancer) | SageMaker Runtime API (IAM / SigV4 auth) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus + Adapter | `aws_appautoscaling_policy` on `GPUUtilization` |
| Kubernetes secret `ngc-secret` | Secrets Manager `nim-demo/ngc-api-key` |

### SageMaker container shim

SageMaker requires containers to serve `GET /ping` and `POST /invocations` on port 8080 and can
only pull images from ECR. `scripts/deploy.sh` mirrors the NIM image from `nvcr.io` into ECR and
layers on `container/`:

- `Caddyfile` — `/ping` → NIM `/v1/health/ready`, `/invocations` → NIM `/v1/chat/completions`
  (streaming supported via `InvokeEndpointWithResponseStream`)
- `serve` — fetches the NGC API key from Secrets Manager, starts NIM's original entrypoint and the proxy

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (image is built for `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances` (default 3)
- ~$1.41/hr per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy

```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars && cd ..   # optional: edit values
./scripts/deploy.sh <your-ngc-api-key>
```

The script runs a two-phase apply: (1) ECR/IAM/secret, (2) build + push the image, (3) model,
endpoint and autoscaling. The endpoint becomes `InService` once NIM has downloaded the model and
built its TensorRT-LLM engine (startup health-check timeout is 30 min).

## Test it

```bash
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo \
  --content-type application/json --body fileb://request.json out.json && cat out.json
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 120
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker \
  --resource-id endpoint/nim-demo/variant/AllTraffic
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

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
| GPU-aware autoscaling | `aws_appautoscaling_policy.gpu` in `terraform/main.tf` | Scales on real GPU utilization, not CPU |
| SageMaker container contract | `container/` | Adapts NIM's OpenAI API to `/ping` + `/invocations` on :8080 |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |

> Note: the NGC API key is stored in Secrets Manager and in Terraform state — keep state in an
> encrypted, access-controlled backend.
