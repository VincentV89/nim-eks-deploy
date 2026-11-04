# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This repo used to run NIM on EKS (`k8s/` manifests + DCGM/Prometheus/HPA). It has been
> migrated to SageMaker: no cluster, VPC, node groups or metrics pipeline to operate.

## Architecture

```
Client ──SigV4──▶ SageMaker endpoint "nim-demo" (ml.g5.xlarge, 1x A10G)
                    │  :8080  Caddy shim   /ping        → NIM /v1/health/ready
                    │                      /invocations → NIM /v1/chat/completions
                    └  :8000  NIM (unmodified, original entrypoint)
                         ↑
       Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, Secrets Manager, IAM, SageMaker, autoscaling) → Docker (NIM + shim image)

| EKS (before)                                   | SageMaker (now)                                               |
|------------------------------------------------|---------------------------------------------------------------|
| VPC + EKS + `g5.xlarge` GPU node group         | `ml.g5.xlarge` endpoint instances (managed)                   |
| `k8s/nim-deployment.yaml`                      | `aws_sagemaker_model` + `sagemaker/` wrapper image in ECR     |
| `k8s/nim-service.yaml` (public LoadBalancer)   | IAM-authenticated `InvokeEndpoint` API (no public listener)   |
| NGC key in a Kubernetes secret                 | NGC key in Secrets Manager, fetched at container start        |
| DCGM exporter + Prometheus + Adapter + HPA     | Target tracking on `/aws/sagemaker/Endpoints` `GPUUtilization` (70%) |
| Readiness probe `/v1/health/ready`             | SageMaker `/ping` health check (proxied to the same route), 30 min startup timeout |

## Prerequisites

- AWS CLI configured with permissions for ECR, IAM, Secrets Manager, SageMaker, Application Auto Scaling
- `terraform` ≥ 1.5, `docker` (with BuildKit), `git`
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for **`ml.g5.xlarge for endpoint usage`** ≥ `max_instances` (default 3)
- ~15 GB free disk for the NIM image and ~$1.4/hr per instance (`ml.g5.xlarge`, us-east-1)

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional: edit values
export NGC_API_KEY=...        # or leave unset and paste it at the hidden prompt
./scripts/deploy.sh
```

`deploy.sh` runs in two stages:

1. `terraform apply` (targeted) creates the ECR repo, the Secrets Manager secret and the IAM role, then writes your NGC key into the secret (it never enters Terraform state or the SageMaker model definition).
2. Pulls `NIM_IMAGE` (default `nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3`), builds `sagemaker/Dockerfile` on top of it, pushes to ECR with an immutable `<git-sha>-<nim-tag>` tag, records the tag in `terraform/image.auto.tfvars`, and runs a full `terraform apply` to create the model, endpoint and autoscaling policy.

The first endpoint creation takes ~10–20 minutes (instance provisioning, weight download from NGC, TensorRT-LLM engine load).

## Test

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

The request body is the OpenAI chat-completions schema; `"stream": true` works with `invoke-endpoint-with-response-stream`.
Container logs: `aws logs tail /aws/sagemaker/Endpoints/nim-demo --follow`.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 5 --duration 300
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker \
  --resource-id endpoint/nim-demo/variant/AllTraffic
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

Target tracking acts on 1-minute CloudWatch metrics, so expect scale-out within a few minutes of sustained load
(new instances also need the startup time above) and scale-in after the 5-minute cooldown.

## Upgrading NIM / changing the shim

```bash
NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:<tag> ./scripts/deploy.sh
```

A new image tag creates a new SageMaker model and endpoint configuration; the endpoint is updated in place (blue/green, no downtime).

## Teardown

```bash
terraform -chdir=terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine | Inside NIM container (automatic) | Optimized model for the A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/Caddyfile` | `/ping` + `/invocations` on :8080 mapped to NIM's OpenAI API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU or request count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
