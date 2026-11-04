# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> This repo previously ran NIM on EKS (VPC + EKS + DCGM/Prometheus + HPA). It now targets
> SageMaker, so there is no cluster, node group, NAT gateway or Kubernetes manifest to manage.

## Architecture

```
Client (IAM / SigV4) → SageMaker endpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                              └─ container: Caddy :8080 → NIM :8000
                                                    ↑
            Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, Secrets Manager, IAM, SageMaker, autoscaling) → Docker (NIM + SageMaker shim) → `scripts/deploy.sh`

| EKS (before) | SageMaker (now) |
|---|---|
| `k8s/nim-deployment.yaml` | `aws_sagemaker_model` + `aws_sagemaker_endpoint` (`terraform/main.tf`) |
| `k8s/nim-service.yaml` (public LoadBalancer :8000) | SageMaker `InvokeEndpoint` API (IAM-authenticated, no public listener) |
| `k8s/nim-hpa.yaml` + DCGM exporter + Prometheus + adapter | `aws_appautoscaling_policy` on the built-in `GPUUtilization` metric |
| NGC key in a Kubernetes secret | NGC key in Secrets Manager, read by the container at startup |
| NIM image pulled from nvcr.io | NIM image + shim mirrored into a private ECR repo (SageMaker requires ECR) |

### SageMaker container shim (`sagemaker/`)

SageMaker containers must listen on port 8080 and serve `GET /ping` and `POST /invocations`.
NIM serves an OpenAI-compatible API on port 8000, so the image adds a small Caddy proxy:

| SageMaker | NIM |
|---|---|
| `GET /ping` | `GET /v1/health/ready` |
| `POST /invocations` | `POST /v1/chat/completions` (streaming passes through) |

`/invocations` accepts **chat-completions** request bodies only.

## Prerequisites

- AWS CLI configured with permissions for ECR, IAM, Secrets Manager, SageMaker, Application Auto Scaling
- `terraform` (>= 1.9) and `docker` installed (the build is `linux/amd64`)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free; needed to pull NIM images and weights)
- An `ml.g5.xlarge` **endpoint** service quota of at least `max_instances` (default 3) in your region
- ~$1.41/hr per `ml.g5.xlarge` instance (us-east-1 on-demand), minimum one instance while the endpoint exists

## Deploy (~20 minutes)

```bash
# Optional: copy and edit terraform/terraform.tfvars.example → terraform/terraform.tfvars
export NGC_API_KEY=<your-ngc-api-key>
export AWS_REGION=us-east-1        # optional; defaults to terraform's `region`
./scripts/deploy.sh
```

The script:
1. `terraform apply`: creates the ECR repo, an empty NGC secret and the SageMaker execution role
2. writes `NGC_API_KEY` into Secrets Manager (it never enters Terraform state or the model definition)
3. pulls the NIM image, builds `sagemaker/Dockerfile` on top of it, and pushes it to ECR with an immutable tag
4. `terraform apply` again with that tag, which creates the model, endpoint config, endpoint and autoscaling.
   The tag and the resolved region are saved to `terraform/deploy.auto.tfvars` (gitignored), so later plain
   `terraform apply` / `terraform destroy` runs keep the endpoint and target the same region.
5. waits for the endpoint to reach `InService`. The first boot downloads weights and builds the TensorRT-LLM engine.

Override the model or image with `NIM_IMAGE=nvcr.io/nim/...:<version>` (pin a version for anything beyond a demo).
Re-running `deploy.sh` rolls out a new image through a SageMaker blue/green endpoint update.

## Test it

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nim-demo \
  --content-type application/json \
  --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --rps 20 --duration 600 \
  --model "$(terraform -chdir=terraform output -raw served_model_name)"
```

Watch it scale:

```bash
aws application-autoscaling describe-scaling-activities --service-namespace sagemaker
aws sagemaker describe-endpoint --endpoint-name nim-demo \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'
```

Target tracking runs on 1-minute CloudWatch metrics and new GPU instances take several minutes
to pass `/ping`, so scale-out is slower than the old pod-level HPA. Run the load test for at least 10 minutes.

## Teardown

```bash
cd terraform && terraform destroy   # uses the region saved in deploy.auto.tfvars
```

Changing `instance_type` on a live endpoint: SageMaker rejects endpoint updates that change the
instance type while autoscaling is registered. Run `terraform destroy -target=aws_appautoscaling_target.nim`
first, then re-run `./scripts/deploy.sh`.

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| SageMaker container contract | `sagemaker/Caddyfile` | Maps `/ping` + `/invocations` onto NIM's API |
| GPU-aware autoscaling | `aws_appautoscaling_policy` in `terraform/main.tf` | Scales on real GPU utilization, not CPU or request count |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
