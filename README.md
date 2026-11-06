# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This project used to run on Amazon EKS (VPC + EKS + DCGM/Prometheus + HPA). It now runs on a
> managed SageMaker endpoint, so there is no cluster, node group, NAT gateway, or metrics stack to run.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" on ml.g5.xlarge (A10G GPU)
                                         │  :8080  Caddy adapter  (/ping, /invocations)
                                         └─ :8000  NIM OpenAI-compatible server
                                              ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Docker (build SageMaker-adapted NIM image) → ECR → Terraform (IAM, model, endpoint, autoscaling)

SageMaker only pulls images from ECR and talks to containers on port 8080 via `GET /ping` and
`POST /invocations`. `sagemaker/Dockerfile` wraps the stock NIM image with a tiny Caddy proxy:

| SageMaker route     | NIM route                   |
|---------------------|-----------------------------|
| `GET /ping`         | `GET /v1/health/ready`      |
| `POST /invocations` | `POST /v1/chat/completions` |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, and Application Auto Scaling
- `terraform`, `docker` installed (`pip install boto3` for the load test)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- `ml.g5.xlarge` endpoint quota in your region (Service Quotas → SageMaker → "ml.g5.xlarge for endpoint usage")
- ~$1.41/hr budget (one ml.g5.xlarge in us-east-1)

## Deploy (~20 minutes)

```bash
# Optional: customise region / instance counts
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Build + push the image to ECR, then create the endpoint and autoscaling
./scripts/deploy.sh <your-ngc-api-key>
```

`deploy.sh` first creates only the ECR repository (`terraform apply -target=...`), pushes the
image, then applies the rest. Terraform waits until the endpoint is `InService`.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

Streaming (`"stream": true`) works with `invoke-endpoint-with-response-stream`.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch instances scale:

```bash
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

SageMaker publishes `GPUUtilization` at 1-minute granularity and target-tracking alarms need a few
datapoints, so scale-out takes several minutes plus new-instance boot time — run the load test longer
than you did on EKS.

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
| SageMaker container contract | `sagemaker/` | Maps `/ping` + `/invocations` on :8080 to NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |

## Security notes

- The endpoint is not publicly reachable; callers need IAM `sagemaker:InvokeEndpoint` and SigV4-signed requests.
- The NGC API key is passed to the container as a model environment variable, which is visible via
  `DescribeModel` to principals with that permission, and is stored in Terraform state. Use a scoped
  NGC key and secure remote state. For production, pre-stage weights in S3 (`model_data_source`) so
  no key is needed at runtime.
