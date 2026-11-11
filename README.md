# NVIDIA NIM on Amazon SageMaker

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on a SageMaker real-time endpoint with GPU autoscaling.

> Previously deployed on EKS; migrated to SageMaker to remove cluster, node group and metrics-pipeline management.

## Architecture

```
Client (SigV4) → SageMaker Endpoint → ml.g5.xlarge instance(s) (A10G GPU)
                                         └─ Caddy :8080 (/ping, /invocations) → NIM :8000
                       ↑
     Application Auto Scaling target-tracks GPUUtilization (CloudWatch)
```

**Stack:** Terraform (ECR, Secrets Manager, IAM, SageMaker endpoint, autoscaling) → Docker (NIM + SageMaker adapter image)

No VPC, NAT gateway, Kubernetes control plane, DCGM exporter or Prometheus to run —
SageMaker manages the instances and publishes GPU metrics natively.

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `docker` installed (an x86_64 host or `docker buildx` for `linux/amd64`)
- Python 3 with `boto3` (for the load test)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images)
- SageMaker service quota for `ml.g5.xlarge for endpoint usage` ≥ `max_instances` (default 3)
- ~$1.41/hr per instance (ml.g5.xlarge, us-east-1 on-demand)

## Deploy (~20 minutes)

```bash
# 1. (optional) customise region / instance type / scaling bounds
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # leave ngc_api_key out; deploy.sh sets it

# 2. Build + push the image and create the endpoint
./scripts/deploy.sh <your-ngc-api-key>

# 3. Test it
aws sagemaker-runtime invoke-endpoint --endpoint-name nim-demo --region us-east-1 \
  --content-type application/json --cli-binary-format raw-in-base64-out \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

`deploy.sh` will:
1. Create the ECR repository and store the NGC key in Secrets Manager.
2. Pull the NIM image from `nvcr.io` and wrap it with the adapter in [`sagemaker/`](sagemaker/)
   (SageMaker requires `GET /ping` and `POST /invocations` on port 8080; NIM serves the OpenAI API on 8000).
3. Push it to ECR with a unique tag.
4. Apply Terraform to create/roll the SageMaker model, endpoint config, endpoint and autoscaling policy.

The NGC key is fetched from Secrets Manager by the container at boot, so it is never stored in the
SageMaker model definition. It *is* stored in Terraform state — keep state in an encrypted backend.

## Load Test (demo autoscaling)

```bash
pip install boto3
python scripts/load_test.py nim-demo --region us-east-1 --rps 20 --duration 600
```

Watch instances scale (GPU target tracking needs a few minutes of CloudWatch datapoints):

```bash
watch -n 30 "aws sagemaker describe-endpoint --endpoint-name nim-demo --region us-east-1 \
  --query 'ProductionVariants[0].[CurrentInstanceCount,DesiredInstanceCount]'"
```

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
| GPU-aware autoscaling | `terraform/main.tf` (`aws_appautoscaling_policy`) | Scales on real GPU utilization, not CPU |
| SageMaker container contract | `sagemaker/` | Maps `/ping` + `/invocations` onto NIM's OpenAI API |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
