# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
User → SageMaker Runtime (SigV4) → Endpoint → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                       ↑
              Application Auto Scaling on GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, IAM, SageMaker endpoint, autoscaling) → Docker (NIM image + SageMaker shim pushed to ECR)

The NIM image serves an OpenAI-compatible API on port 8000. SageMaker requires
`GET /ping` and `POST /invocations` on port 8080, so `sagemaker/` wraps the
NIM image with a tiny Caddy proxy:

| SageMaker route | NIM route |
|-----------------|-----------|
| `GET /ping` | `/v1/health/ready` |
| `POST /invocations` | `/v1/chat/completions` |

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (building on x86_64 recommended; the image is `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances`
- ~$1.40/hr budget (one ml.g5.xlarge endpoint instance, us-east-1 on-demand)

## Deploy

```bash
# 1. (optional) customise settings
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# 2. Build + push image to ECR, then create the endpoint and autoscaling
./scripts/deploy.sh <your-ngc-api-key>

# 3. Test it
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON
aws sagemaker-runtime invoke-endpoint --region us-east-1 --endpoint-name nim-demo \
  --content-type application/json --body fileb://request.json out.json && cat out.json
```

The first boot downloads weights and builds the TensorRT-LLM engine; the
endpoint's container start-up health check timeout is set to 30 minutes.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600 --region us-east-1
```

Watch instances scale:
`aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'`

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## Migrating from the EKS version

This repo previously ran NIM on EKS (`k8s/` manifests, Helm DCGM/Prometheus stack, HPA).
Those have been replaced:

| EKS | SageMaker |
|-----|-----------|
| VPC + EKS cluster + GPU node group | Managed SageMaker endpoint (no VPC/cluster to run) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `sagemaker/` image in ECR |
| `k8s/nim-service.yaml` (public LoadBalancer) | SageMaker Runtime API (IAM / SigV4 authenticated) |
| DCGM Exporter + Prometheus + Adapter + HPA | Built-in `GPUUtilization` metric + Application Auto Scaling |
| Readiness/liveness probes | `/ping` health check |

If you have an existing EKS deployment, check out the last EKS commit and run
`terraform destroy` there before applying this version — the Terraform state is not migrated.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
