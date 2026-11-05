# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM as a SageMaker real-time endpoint with GPU autoscaling.

## Architecture

```
Client (SigV4) → SageMaker Runtime → Endpoint "nim-demo" → NIM container(s) on ml.g5.xlarge (A10G GPU)
                                                ↑
                      Application Auto Scaling target-tracks native GPUUtilization (CloudWatch)
```

**Stack:** Docker (wrap NIM for SageMaker → ECR) → Terraform (IAM, model, endpoint, autoscaling)

The NIM container serves an OpenAI-compatible API on `:8000`. SageMaker requires `GET /ping` and
`POST /invocations` on `:8080`, so `sagemaker/` builds a thin wrapper image that adds a Caddy reverse proxy:

| SageMaker path | NIM path |
|----------------|----------|
| `GET /ping` | `/v1/health/ready` |
| `POST /invocations` | `/v1/chat/completions` |

## Prerequisites

- AWS CLI configured with permissions for SageMaker, ECR, IAM and Application Auto Scaling
- `terraform`, `docker` installed (x86_64 build host recommended — the NIM image is ~10 GB+)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- An `ml.g5.xlarge` endpoint-usage service quota ≥ `max_instances` in your region
- Budget for one `ml.g5.xlarge` instance running 24/7 (check SageMaker pricing for your region)

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional: tweak instance type / scaling
./scripts/deploy.sh <your-ngc-api-key> us-east-1
```

The script creates the ECR repo, builds and pushes the wrapped NIM image, then applies the rest of the
Terraform. The first boot downloads weights and loads the TensorRT-LLM engine, so the endpoint may take
10–20 minutes to become `InService`.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch scaling:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker --region us-east-1
aws sagemaker describe-endpoint --endpoint-name nim-demo --query 'ProductionVariants[0].CurrentInstanceCount'
```

Target tracking alarms evaluate over several minutes and each new instance has to boot NIM, so scale-out is
slower than the old Kubernetes HPA — run the load test for ≥10 minutes to see it.

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## Security notes

- The NGC API key is passed to the container as the `NGC_API_KEY` environment variable on the SageMaker
  model. It is marked `sensitive` in Terraform, but is stored in Terraform state and is returned by
  `sagemaker:DescribeModel` — use an encrypted remote state backend and restrict `DescribeModel`.
- The endpoint is not publicly reachable: callers need `sagemaker:InvokeEndpoint` IAM permission (SigV4).

## Migrating from the previous EKS deployment

This repo previously ran NIM on EKS (VPC + EKS cluster + GPU node group, `k8s/` manifests, DCGM Exporter +
Prometheus + Prometheus Adapter + HPA). If you still have that stack deployed, destroy it from the
pre-migration commit **before** applying this version, since the Terraform resources were replaced:

```bash
git checkout <pre-migration-commit> -- terraform && (cd terraform && terraform destroy)
git checkout HEAD -- terraform
```

| EKS | SageMaker |
|-----|-----------|
| VPC, EKS cluster, GPU node group | Managed SageMaker endpoint (no VPC/cluster to run) |
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer) | SageMaker Runtime `InvokeEndpoint` (IAM-authenticated) |
| `k8s/nim-hpa.yaml` + DCGM/Prometheus/Adapter | `aws_appautoscaling_policy` on native `GPUUtilization` |
| `ngc-secret` image pull secret | Image mirrored into ECR |
| `kubectl logs` | CloudWatch Logs `/aws/sagemaker/Endpoints/nim-demo` |

Clients change from `POST http://<lb>:8000/v1/chat/completions` to `InvokeEndpoint` with the same JSON body.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/` | `/ping` + `/invocations` on `:8080` |
| GPU-aware autoscaling | `terraform/main.tf` | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
