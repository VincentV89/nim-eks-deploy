# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This project previously ran on EKS (Deployment + HPA on DCGM metrics). It now runs on a
> fully managed SageMaker endpoint — no cluster, node groups, Prometheus or Helm to operate.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → ml.g5.xlarge instance(s) (A10G GPU)
                                                               └─ proxy :8080 (/ping, /invocations)
                                                                    └─ NIM :8000 (OpenAI-compatible API)
                                          ↑
              Application Auto Scaling target-tracks the GPUUtilization CloudWatch metric
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (wrap NIM image for SageMaker, push to ECR)

| Layer | Before (EKS) | After (SageMaker) |
|-------|--------------|-------------------|
| Compute | EKS managed node group `g5.xlarge` | Endpoint variant `ml.g5.xlarge` |
| Image source | `nvcr.io` via `imagePullSecret` | Mirrored to ECR (SageMaker only pulls from ECR) |
| Serving contract | Pod port 8000 | Container port 8080, `/ping` + `/invocations` (`sagemaker/proxy.py`) |
| Health checks | readiness/liveness probes | `/ping` → NIM `/v1/health/ready`, 30 min startup timeout |
| Ingress | `LoadBalancer` Service (public ALB/NLB) | IAM-authenticated SageMaker Runtime API |
| Autoscaling | HPA on `DCGM_FI_DEV_GPU_UTIL` (DCGM + Prometheus + Adapter) | Target tracking on `GPUUtilization` (built-in) |
| Networking | VPC + NAT gateway | None required |

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (an x86_64 build host is recommended — the NIM image is ~10 GB, `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- `ml.g5.xlarge` endpoint quota in your region (request via Service Quotas if it is 0)
- ~$1.40/hr budget (one `ml.g5.xlarge` endpoint instance, us-east-1 on-demand)

## Deploy (~20-30 minutes)

```bash
# Optional: customise region / instance type / scaling bounds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Creates ECR repo, builds + pushes the SageMaker-wrapped NIM image,
# then creates the SageMaker model, endpoint and autoscaling policy.
./scripts/deploy.sh <your-ngc-api-key>
```

Test it:

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

`/invocations` routes to NIM's `/v1/chat/completions` by default, or `/v1/completions` when the
body contains `prompt` but no `messages`. Any other `/v1/*` route can be selected with
`--custom-attributes route=/v1/<path>`. Streaming (`"stream": true`) works with
`invoke-endpoint-with-response-stream`.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch instances scale (scale-out needs a few minutes of sustained GPU > 70%):

```bash
watch -n 30 "aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

## Teardown

```bash
cd terraform && terraform destroy   # prompts for ngc_api_key; any value works for destroy
```

## Notes

- The NGC API key is passed to the container as the `NGC_API_KEY` environment variable so NIM can
  download weights at startup. SageMaker stores model environment variables in plain text in the
  model definition (visible via `DescribeModel`), and the key is also kept in Terraform state —
  use a restricted-scope NGC key and protect your state backend.
- Re-running `deploy.sh` rebuilds the image with a content-derived tag; a changed image creates a new
  model + endpoint config and SageMaker performs a blue/green update of the endpoint.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/` | Adapts NIM's OpenAI API to `/ping` + `/invocations` on :8080 |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
