# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                                ↑
                         Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

Inside each instance, a small Caddy shim (`sagemaker/`) adapts NIM to the SageMaker hosting contract:

| SageMaker route (:8080) | NIM route (:8000) |
|---|---|
| `GET /ping` | `/v1/health/ready` |
| `POST /invocations`, `/invocations-response-stream` | `/v1/chat/completions` |

**Stack:** Docker (NIM + shim → ECR) → Terraform (IAM, Secrets Manager, SageMaker model/endpoint, autoscaling)

No VPC, EKS cluster, node groups, load balancer, DCGM exporter, Prometheus or HPA to operate.

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Secrets Manager and Application Auto Scaling
- `terraform`, `docker` installed (an x86_64 build host is recommended — the NIM image is ~10GB+)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances` (default 3)
- ~$1.41/hr per `ml.g5.xlarge` instance (us-east-1 on-demand), billed while the endpoint exists

## Deploy (~20-30 minutes)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # edit with your values
./scripts/deploy.sh <your-ngc-api-key>
```

`deploy.sh`:
1. Creates the ECR repository and an (empty) Secrets Manager secret
2. Stores the NGC API key in the secret — it is never written to Terraform state or the SageMaker model environment
3. Builds `sagemaker/Dockerfile` on top of the NIM image and pushes it to ECR
4. Applies the rest of the Terraform (model, endpoint config, endpoint, autoscaling) and waits for `InService`

Test it:

```bash
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --body fileb://request.json out.json && cat out.json
```

Streaming: add `"stream": true` to the body and call `invoke-endpoint-with-response-stream`.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Target tracking acts on CloudWatch alarms (1-minute metrics, several datapoints), so sustain load for
5+ minutes. Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region us-east-1
aws sagemaker describe-endpoint --endpoint-name nim-demo --region us-east-1 \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

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
| SageMaker container contract | `sagemaker/` | `/ping` + `/invocations` on :8080 mapped onto NIM's OpenAI API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy.gpu`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
