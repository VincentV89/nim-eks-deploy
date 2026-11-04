# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
User → SageMaker Runtime (SigV4) → Endpoint → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                       ↑
              Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Docker (wrap NIM for SageMaker) → ECR → Terraform (model, endpoint, autoscaling)

There is no cluster, VPC, load balancer, or metrics pipeline to run — SageMaker
manages instances, health checks, and publishes GPU metrics to CloudWatch natively.

### How NIM runs on SageMaker

SageMaker requires containers to serve `GET /ping` and `POST /invocations` on
port 8080 and to be pulled from ECR. `sagemaker/` wraps the stock NIM image with
a tiny stdlib-only shim:

| SageMaker | → NIM |
|-----------|-------|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` with `messages` | `POST /v1/chat/completions` |
| `POST /invocations` without `messages` | `POST /v1/completions` |

Responses are streamed through, so `InvokeEndpointWithResponseStream` with
`"stream": true` works too. The NGC API key is stored in Secrets Manager and
fetched by the container at startup.

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (building an x86_64 image; on Apple Silicon/ARM this uses emulation)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (needed to pull NIM images and model weights)
- `ml.g5.xlarge` endpoint quota in your region (Service Quotas → SageMaker)
- ~$1.50/hr budget (one ml.g5.xlarge endpoint instance)

## Deploy (~20 minutes)

```bash
# Optional: customize region / instance counts
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Builds + pushes the image to ECR, then terraform apply
NGC_API_KEY=nvapi-... ./scripts/deploy.sh
```

Override `NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:<tag>` to pick another NIM
version. If your NIM version starts the server from a different path, set the
`NIM_START_CMD` environment variable on the model (default `/opt/nim/start_server.sh`).

## Test it

```bash
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --body fileb://request.json out.json && cat out.json
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch instances scale:

```bash
watch -n 15 "aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

Scale-out on SageMaker takes several minutes (new instance + NIM warm-up), so run the
load test long enough to see it.

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
| SageMaker container contract | `sagemaker/` | Adapts NIM's OpenAI API to `/ping` + `/invocations` |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy.gpu`) | Scales on real GPU utilization, not invocation count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |

## Migrating from the EKS version

| EKS (before) | SageMaker (now) |
|--------------|-----------------|
| VPC + EKS cluster + GPU node group | Managed SageMaker endpoint |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | SageMaker Runtime API (IAM/SigV4 auth) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus + Adapter | `aws_appautoscaling_policy` on CloudWatch `GPUUtilization` |
| Readiness/liveness probes | `/ping` + `container_startup_health_check_timeout_in_seconds` |
| NGC key in a k8s Secret | NGC key in Secrets Manager |

Destroy any existing EKS stack (`terraform destroy` on the previous revision) before applying this one.
