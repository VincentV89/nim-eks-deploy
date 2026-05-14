# NVIDIA NIM on Amazon SageMaker

Deploy **Llama 3.1 8B Instruct** via NVIDIA NIM on Amazon SageMaker with autoscaling.

## Architecture

```
User -> SageMaker Endpoint -> NIM Container on ml.g5.xlarge (A10G GPU)
                                    ^
                               Autoscaling on InvocationsPerInstance
```

**Stack:** Terraform (infra + endpoint) -> AWS CLI (wait/test)

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Terraform](https://terraform.io) >= 1.5 | Provision SageMaker resources |
| [AWS CLI](https://aws.amazon.com/cli/) v2 | Wait for endpoint, invoke for testing |
| Python 3.9+ with boto3 | Load testing via SageMaker runtime API |
| NGC API Key | Access NVIDIA NIM container images ([get one here](https://org.ngc.nvidia.com/setup)) |

> **Budget note:** ml.g5.xlarge costs approximately $3.50/hr while the endpoint is active.

## Deploy

1. Configure your variables:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set your ngc_api_key
```

2. Run the deploy script:

```bash
./scripts/deploy.sh <YOUR_NGC_API_KEY>
```

This will:
- Run `terraform init` and `terraform apply`
- Wait for the SageMaker endpoint to reach InService status
- Print the endpoint name and a sample invocation command

## Test

Invoke the endpoint directly with the AWS CLI:

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name <ENDPOINT_NAME> \
  --content-type application/json \
  --body '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  /dev/stdout
```

## Load Test

Run the load test script against your SageMaker endpoint:

```bash
# SageMaker mode (recommended)
python scripts/load_test.py --endpoint-name <ENDPOINT_NAME> --rps 10 --duration 60

# Direct HTTP mode (if testing via API Gateway or local)
python scripts/load_test.py http://<URL>:8000 --rps 10 --duration 60
```

The script reports p50, p95, p99 latency and throughput (req/s).

## Teardown

```bash
cd terraform
terraform destroy
```

## CI/CD

Pull requests that modify `terraform/**` or `scripts/**` trigger the **Kiro Infrastructure Review** workflow, which performs automated security and configuration analysis.

## Key Concepts

| Concept | Description |
|---------|-------------|
| Managed GPU Hosting | SageMaker provisions and manages GPU instances (ml.g5.xlarge with A10G) |
| Autoscaling Policy | Target-tracking policy scales instances based on InvocationsPerInstance metric |
| Endpoint Variants | Production variants allow traffic splitting and canary deployments |
| Container Serving | NIM container from nvcr.io runs the optimized TensorRT-LLM engine |
| Infrastructure as Code | Terraform manages all resources: IAM role, model, endpoint config, endpoint, autoscaling |
