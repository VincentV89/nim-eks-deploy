# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on an Amazon SageMaker real-time endpoint with GPU autoscaling.

> This project previously ran NIM on Amazon EKS. It now uses a managed SageMaker
> endpoint, so there is no cluster, VPC/NAT, node group, Helm monitoring stack or
> HPA to operate.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                                ↑
                         Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Docker (NIM image + SageMaker shim) → ECR → Terraform (SageMaker model, endpoint, autoscaling)

### How NIM is adapted to SageMaker

SageMaker sends traffic to port `8080` on `GET /ping` and `POST /invocations`, while NIM serves an
OpenAI-compatible API on port `8000`. [`sagemaker/Dockerfile`](sagemaker/Dockerfile) builds on the NIM image
and adds a small [Caddy](https://caddyserver.com/) reverse proxy ([`sagemaker/Caddyfile`](sagemaker/Caddyfile)):

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` |

[`sagemaker/serve.sh`](sagemaker/serve.sh) starts NIM and the proxy, and exits as soon as either one stops, so
SageMaker replaces the unhealthy instance. If your NIM image uses a different start script, set
`NIM_START_CMD` in the container environment (default: `/opt/nim/start_server.sh`).

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Application Auto Scaling and CloudWatch
- `terraform`, `docker` (with BuildKit) installed
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free; needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances` (default 3)
- ~$1.41/hr per `ml.g5.xlarge` instance in us-east-1 (check current SageMaker pricing)

## Deploy (~20-30 minutes)

```bash
# Optional: customise region / instance type / scaling limits
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Builds the image, pushes it to ECR and creates the endpoint + autoscaling
AWS_REGION=us-east-1 ./scripts/deploy.sh <your-ngc-api-key>
```

The script:
1. creates the ECR repository (`terraform apply -target=aws_ecr_repository.nim`)
2. builds `sagemaker/Dockerfile` on top of the NIM image (`NIM_IMAGE` overrides the base image)
3. pushes it to ECR and pins the deployment to the pushed image digest
4. applies the rest of the Terraform config and waits for the endpoint to reach `InService`

On first boot NIM downloads the weights and builds the TensorRT-LLM engine. The endpoint stays `Creating`
until `/ping` succeeds (`startup_health_check_timeout`, default 1800s).

## Test it

SageMaker endpoints are not public HTTP URLs. Requests must be SigV4-signed, for example with the AWS CLI:

```bash
aws sagemaker-runtime invoke-endpoint \
  --region us-east-1 --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

Or with Python (`boto3.client("sagemaker-runtime").invoke_endpoint(...)`). The request body is the same
OpenAI chat-completions payload as before.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch it scale. Target tracking acts on CloudWatch alarms, so keep the load test running for several minutes:

```bash
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker
```

Logs: `aws logs tail /aws/sagemaker/Endpoints/nim-demo --follow`

## Teardown

```bash
cd terraform && terraform destroy
```

## Notes and caveats

- **NGC API key**: passed to Terraform as `TF_VAR_ngc_api_key` (marked sensitive). It is set as a container
  environment variable on the SageMaker model, so it is visible in `DescribeModel` output and Terraform state.
  Restrict those permissions and protect your state backend.
- **Updating the instance type**: SageMaker rejects endpoint updates that change the instance type of an
  autoscaled variant. Deregister the scaling target first (`terraform destroy -target=aws_appautoscaling_policy.gpu -target=aws_appautoscaling_target.nim`)
  and then apply.
- **Images**: SageMaker only pulls from ECR, which is why the NIM image is mirrored there. Build on (or pass
  `--platform linux/amd64` from) an x86_64 host. Building from Apple Silicon or ARM uses emulation and is slow.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/` | Maps `/ping` + `/invocations` on :8080 to NIM's API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy.gpu`) | Scales on real GPU utilization, not CPU or request count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
