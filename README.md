# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> Migrated from Amazon EKS. The EKS cluster, VPC, Kubernetes manifests, DCGM exporter,
> Prometheus and HPA have been replaced by a managed SageMaker endpoint and
> Application Auto Scaling.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → ml.g5.xlarge instance(s) (A10G GPU)
                                                              └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                                         ↑
           Application Auto Scaling target-tracks CloudWatch GPUUtilization (70%)
```

**Stack:** Docker (NIM + SageMaker shim → ECR) → Terraform (IAM, ECR, SageMaker model/endpoint, autoscaling)

| EKS (before) | SageMaker (after) |
|---|---|
| `module.vpc` + `module.eks` + GPU node group | `aws_sagemaker_endpoint` on `ml.g5.xlarge` |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `sagemaker/` shim image in ECR |
| `k8s/nim-service.yaml` (public LoadBalancer) | IAM-authenticated SageMaker Runtime API (no public listener) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus Adapter | `aws_appautoscaling_policy` on built-in `GPUUtilization` metric |
| `ngc-secret` Kubernetes secrets | `NGC_API_KEY` container env var (Terraform `sensitive` variable) |

### Why a shim image?

SageMaker only pulls images from ECR and requires containers to serve `GET /ping`
and `POST /invocations` on port 8080. `sagemaker/Dockerfile` layers a tiny Caddy
reverse proxy on top of the NIM image that maps:

- `/ping` → `/v1/health/ready`
- `/invocations` → `/v1/chat/completions` (OpenAI-compatible request/response body)

If your NIM version uses a different start command, override `NIM_START_CMD`
(default `/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start_server.sh`).

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM and Application Auto Scaling
- An S3 bucket for Terraform state (versioned, encrypted, public access blocked) — state holds the NGC key
- `terraform` (>= 1.10) and `docker` (with `linux/amd64` build support) installed
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances`
- ~$1.41/hr per instance (`ml.g5.xlarge` on-demand, us-east-1)

## Deploy (~20 minutes)

```bash
export NGC_API_KEY=nvapi-...          # never commit this
export AWS_REGION=us-east-1
export TF_STATE_BUCKET=my-tf-state     # or create terraform/backend.hcl from backend.hcl.example
export EXPECTED_AWS_ACCOUNT_ID=123456789012   # optional: abort if credentials point elsewhere
./scripts/deploy.sh
```

`deploy.sh` will:
0. print the caller identity (and abort on an `EXPECTED_AWS_ACCOUNT_ID` mismatch), then
   `terraform init` against the encrypted S3 backend
1. create the KMS key and ECR repository (`terraform apply -target=aws_ecr_repository.nim`)
2. pull the NIM image from `nvcr.io`
3. build the SageMaker shim and push it to the tag-immutable ECR repository with a unique tag
4. `terraform apply` the model, endpoint config, endpoint and autoscaling policy

Optional overrides: `cp terraform/terraform.tfvars.example terraform/terraform.tfvars`.
The NIM image is pinned (`NIM_IMAGE`, default `nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3`);
`:latest` is rejected so deployments are reproducible.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --region us-east-1 --endpoint-name nim-demo \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Target tracking evaluates over several minutes, so run the load for at least ~5–10 minutes.
Watch scaling:

```bash
aws sagemaker describe-endpoint --endpoint-name nim-demo --region us-east-1 \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused TF_VAR_image_tag=unused terraform destroy
```

## Security notes

- The endpoint is only reachable through the SigV4-authenticated SageMaker Runtime API.
- SageMaker has no native secret injection for container environment variables, so
  `NGC_API_KEY` is visible via `sagemaker:DescribeModel` and stored in Terraform state.
  State is therefore kept in an encrypted S3 backend with lockfile locking; restrict
  `DescribeModel` and state-bucket access accordingly.
- The shim container runs as a non-root user (UID 1000); root is only used at build time.
- ECR images and endpoint logs are encrypted with a customer-managed, auto-rotating KMS key;
  logs are retained for `log_retention_days` (default 30). `ml.g5` instance storage is
  NVMe, which SageMaker encrypts in hardware (it does not accept a KMS key for it).
- The endpoint is not attached to a VPC, so there are no security groups to manage; NIM needs
  outbound internet to download weights from NGC, so network isolation is not enabled.

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
