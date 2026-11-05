# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker endpoint → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                           ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (SageMaker-wrapped NIM image)

SageMaker containers must serve `GET /ping` and `POST /invocations` on port 8080, and the image must be in ECR.
`docker/` adds a small Caddy reverse proxy to the stock NIM image:

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM and Application Auto Scaling
- `terraform`, `docker` installed (the image is built for `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` (≥ `max_instances`)
- ~$1.40/hr per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy

```bash
# 1. (optional) customise region / instance type / scaling limits
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# 2. Create ECR repo, build + push the image, create the endpoint (~10-20 min)
./scripts/deploy.sh <your-ngc-api-key>

# 3. Test it
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

The request body is the OpenAI chat-completions format, so it is the same body you would send to NIM directly.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600
```

Watch instances scale:

```bash
watch -n 30 "aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

Scaling uses CloudWatch metrics, so it reacts more slowly than the old Kubernetes HPA. Each new
instance also has to start the container and load the model. Run the load test for several minutes.

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
| SageMaker container contract | `docker/` | `/ping` + `/invocations` on :8080, mapped to NIM's API |
| GPU-aware autoscaling | `aws_appautoscaling_policy.gpu_util` in `terraform/main.tf` | Scales on real GPU utilization, not invocation count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |

## Security notes

- `NGC_API_KEY` is passed to the container as an environment variable. SageMaker stores it in plain text
  in the model definition (`DescribeModel`) and Terraform stores it in plain text in state. Restrict
  access to both, or pre-stage the model weights in S3 so the endpoint does not need the key at runtime.
- The endpoint has no public network listener. Callers need `sagemaker:InvokeEndpoint` IAM permission.
