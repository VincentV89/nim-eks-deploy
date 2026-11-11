# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker endpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                          └─ :8080 Caddy shim (/ping, /invocations) → :8000 NIM
                       ↑
   Application Auto Scaling target-tracks CloudWatch GPUUtilization
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (NIM + SageMaker shim image in ECR)

SageMaker can only pull images from ECR and requires containers to serve `GET /ping` and
`POST /invocations` on port 8080. `sagemaker/` wraps the stock NIM image with a tiny Caddy
reverse proxy mapping `/ping → /v1/health/ready` and `/invocations → /v1/chat/completions`.
GPU metrics and autoscaling are built into SageMaker, so no DCGM/Prometheus/HPA stack is needed.

## Prerequisites

- AWS CLI configured with permissions for ECR, IAM, SageMaker, Application Auto Scaling
- `terraform`, `docker` (BuildKit enabled) installed
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- ml.g5.xlarge SageMaker endpoint quota in your region, and ~$1.50/hr budget per instance

## Deploy (~20 minutes)

```bash
# 1. (optional) configure region / instance counts
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# 2. Create ECR repo, build + push the image, create the endpoint + autoscaling
./scripts/deploy.sh <your-ngc-api-key>

# 3. Test it
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo \
  --content-type application/json --body fileb://request.json out.json && cat out.json
```

The first boot downloads weights and builds the TensorRT-LLM engine; the endpoint stays
`Creating` until NIM is ready (startup health-check timeout is 30 min).

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600
```

Watch instances scale:
`aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].CurrentInstanceCount'`
(target tracking evaluates CloudWatch metrics per minute, so scale-out takes a few minutes, and
each new instance needs NIM's startup time before it serves traffic).

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## Security notes

- The NGC key is passed to the container as the `NGC_API_KEY` environment variable; it is visible
  via `sagemaker:DescribeModel` and stored in Terraform state. Restrict those accordingly.
- Invocation requires IAM (`sagemaker:InvokeEndpoint`) — there is no public load balancer.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/` | Adapts NIM's OpenAI API to `/ping` + `/invocations` |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy.gpu`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
