# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker Endpoint → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                          ↑
               Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (NIM image + SageMaker shim) → CloudWatch (metrics)

SageMaker only pulls images from ECR and expects `GET /ping` + `POST /invocations` on port 8080,
so `container/` wraps the NGC NIM image with a tiny Caddy proxy:

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` |

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` (with buildx) installed
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images)
- Service quota for `ml.g5.xlarge for endpoint usage` (≥ max instances)
- ~$1.40/hr budget per ml.g5.xlarge instance (us-east-1 on-demand)

## Deploy (~20 minutes)

```bash
export NGC_API_KEY=<your-ngc-api-key>
./scripts/deploy.sh            # creates ECR, pushes image, creates endpoint + autoscaling
```

Optional overrides: `AWS_REGION`, `NIM_IMAGE`, `IMAGE_TAG`, and the variables in
`terraform/terraform.tfvars.example`.

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
python scripts/load_test.py nim-demo --rps 20 --duration 600
```

Watch instances scale:

```bash
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

Target tracking evaluates CloudWatch metrics at 1-minute granularity, so scale-out takes a few
minutes plus instance boot (weight download + TensorRT engine load).

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
| SageMaker container contract | `container/` | Maps `/ping` + `/invocations` onto NIM's OpenAI API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
