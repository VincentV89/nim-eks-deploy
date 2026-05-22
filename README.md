# NVIDIA NIM on Amazon EKS

Deploy Llama 3.1 8B Instruct via NVIDIA NIM on EKS with GPU autoscaling. (edited 4)

## Architecture

```
User → ALB → NIM Pod(s) on g5.xlarge (A10G GPU)
                  ↑
            HPA scales on GPU utilization (DCGM metrics)
```

**Stack:** Terraform (infra) → kubectl (NIM) → Helm (GPU monitoring) → HPA (autoscale)

## Prerequisites

- AWS CLI configured with admin-level permissions
- `terraform`, `kubectl`, `helm` installed
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images)
- ~$3.50/hr budget (one g5.xlarge on-demand)

## Deploy (15 minutes)

```bash
# 1. Infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init && terraform apply

# 2. Connect kubectl
aws eks update-kubeconfig --name nim-demo --region us-east-1

# 3. Deploy NIM + monitoring + autoscaling
cd ..
./scripts/deploy.sh <your-ngc-api-key>

# 4. Test it
export NIM_URL=$(kubectl get svc nim-llm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$NIM_URL:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

## Load Test (demo autoscaling)

```bash
pip install aiohttp
python scripts/load_test.py http://$NIM_URL:8000 --rps 20 --duration 120
```

Watch pods scale: `kubectl get hpa nim-llm -w`

## Teardown

```bash
cd terraform && terraform destroy
```

## CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/kiro-review.yml`) that uses [Kiro CLI headless mode](https://kiro.dev/docs/cli/headless/) to automatically review infrastructure changes on every PR. See the workflow file for details.

## Key Concepts

| Concept | Where it appears | Why it matters |
|---------|-----------------|----------------|
| TensorRT-LLM engine compilation | Inside NIM container (automatic) | Optimizes model for A10G architecture |
| KV cache management | NIM runtime | Enables concurrent request serving |
| Continuous batching | NIM inference server | Keeps GPU saturated under load |
| GPU-aware autoscaling | `k8s/nim-hpa.yaml` | Scales on real GPU utilization, not CPU |
| Infrastructure as Code | `terraform/` | Reproducible, version-controlled infra |
