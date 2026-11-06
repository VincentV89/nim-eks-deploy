# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This project previously ran NIM on Amazon EKS (Kubernetes Deployment + DCGM/Prometheus/HPA).
> It now uses a fully managed SageMaker endpoint: no cluster, node groups, VPC/NAT or metrics stack to run.

## Architecture

```
Client ──SigV4──▶ SageMaker endpoint ──▶ ml.g5.xlarge instance(s) (A10G GPU)
                        │                  └─ container: Caddy :8080 ──▶ NIM :8000
                        │                       /ping        → /v1/health/ready
                        │                       /invocations → /v1/chat/completions
                        ▲
     Application Auto Scaling target-tracks the built-in GPUUtilization metric
```

**Stack:** Terraform (ECR, IAM, SageMaker model/endpoint, autoscaling) → Docker (wrap NIM image for SageMaker) → ECR

| Path | Purpose |
|------|---------|
| `terraform/` | ECR repo, SageMaker execution role, model, endpoint config, endpoint, autoscaling policy |
| `docker/` | Thin wrapper over the NIM image that adds the SageMaker container contract (port 8080, `/ping`, `/invocations`) |
| `scripts/deploy.sh` | End-to-end deploy: ECR → build/push image → endpoint |
| `scripts/load_test.py` | Concurrent load generator against the endpoint |

## Prerequisites

- AWS CLI configured with permissions for ECR, IAM, SageMaker and Application Auto Scaling
- `terraform`, `docker` installed (image is built for `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances` (default 3)
- ~$1.40/hr per `ml.g5.xlarge` instance (us-east-1 on-demand)

## Deploy (~20 minutes)

```bash
# Optional: customise region / instance type / scaling bounds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Creates ECR repo, builds + pushes the SageMaker-wrapped NIM image, creates the endpoint
export NGC_API_KEY=<your-ngc-api-key>
./scripts/deploy.sh
```

Endpoint creation waits for the container to pass `/ping`; on first boot NIM downloads weights and
builds/loads the TensorRT-LLM engine, so this can take 10+ minutes (health check timeout is 30 min).

### Test it

SageMaker endpoints are invoked with SigV4-signed requests (no public URL):

```bash
cat > request.json <<'JSON'
{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}
JSON

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body file://request.json out.json && cat out.json
```

Streaming works via `invoke-endpoint-with-response-stream` with `"stream": true` in the body.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600
```

Watch it scale:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

SageMaker target tracking reacts on CloudWatch alarm periods (minutes, not seconds) and each new
instance must boot NIM, so run the load test for several minutes to see a scale-out.

## Teardown

```bash
cd terraform && TF_VAR_ngc_api_key=unused terraform destroy
```

## Migrating from the EKS version

The EKS resources (VPC, EKS cluster, node groups, k8s manifests, Helm releases) are no longer defined.
If you have an existing EKS deployment, run `terraform destroy` **from the previous commit** before
applying this version, otherwise the old resources are left orphaned in your state/account.

| EKS (before) | SageMaker (now) |
|--------------|-----------------|
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` |
| `k8s/nim-service.yaml` (public LoadBalancer :8000) | `aws_sagemaker_endpoint` (IAM-authenticated, SigV4) |
| `k8s/nim-hpa.yaml` + DCGM + Prometheus Adapter | `aws_appautoscaling_policy` on `GPUUtilization` |
| GPU node group (`g5.xlarge`) | Production variant (`ml.g5.xlarge`) |
| `ngc-secret` pull secret | Image mirrored to ECR by `deploy.sh` |
| `ngc-secret` env secret | `NGC_API_KEY` container env var (sensitive Terraform var) |

## Security notes

- The endpoint is not publicly reachable; callers need `sagemaker:InvokeEndpoint` IAM permission.
- `NGC_API_KEY` is passed to the container as an environment variable, which is visible to principals
  with `sagemaker:DescribeModel`. It is stored in Terraform state — use an encrypted remote backend.
  For production, consider pre-caching model weights in S3 (`NIM_CACHE_PATH` + `ModelDataSource`) to
  remove the runtime NGC dependency.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `docker/` | Maps `/ping` + `/invocations` on :8080 onto the NIM API |
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not invocations or CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
