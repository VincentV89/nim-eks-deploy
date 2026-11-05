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

- AWS CLI configured with permissions for SageMaker, ECR, IAM, Secrets Manager and Application Auto Scaling
- `terraform`, `docker` installed (x86_64 build host recommended — the NIM image is ~10 GB+)
- [NVIDIA NGC API Key](https://org.ngc.nvidia.com/) (free — needed to pull NIM images and model weights)
- An `ml.g5.xlarge` endpoint-usage service quota ≥ `max_instances` in your region
- Budget for one `ml.g5.xlarge` instance running 24/7 (check SageMaker pricing for your region)

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional: tweak instance type / scaling
cp terraform/backend.tf.example terraform/backend.tf               # recommended: encrypted S3 state
./scripts/deploy.sh us-east-1        # prompts for the NGC API key (input is not echoed)
# or, non-interactive:  NGC_API_KEY=... ./scripts/deploy.sh us-east-1
```

The key is never taken as a command-line argument. The script checks for `aws`, `terraform` and `docker` and
valid AWS credentials, creates the ECR repo and an empty Secrets Manager secret, stores the NGC key in that
secret, pulls the NIM image and pins it to its `sha256` digest, reads the upstream user and start command with
`docker inspect`, builds and pushes the wrapped image, writes the pushed tag to `terraform/image.auto.tfvars`
(git-ignored) and applies the rest of the Terraform. `docker logout nvcr.io` runs on exit, even on failure.

Set `NIM_IMAGE` to pin a specific NIM release (e.g. `NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:<version>`);
the default `:latest` is resolved to a digest at build time, which is printed and stored as an image label.

Because the tag is recorded in `image.auto.tfvars`, a later plain `terraform apply` (for example to change
`max_instances`) keeps using the pushed image. `image_tag` has no default, so applying without it fails
instead of pointing the endpoint at a tag that doesn't exist.

The first boot downloads weights and loads the TensorRT-LLM engine, so the endpoint may take
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

Real-time `InvokeEndpoint` calls time out after 60 seconds, and `/invocations` returns the full (non-streamed)
response, so keep `max_tokens` moderate. Long generations need `InvokeEndpointWithResponseStream`, which this
wrapper does not implement yet.

Target tracking alarms evaluate over several minutes and each new instance has to boot NIM, so scale-out is
slower than the old Kubernetes HPA — run the load test for ≥10 minutes to see it.

## Updating the endpoint

- **New image:** rerun `deploy.sh`. A new model and endpoint config are created and the endpoint is updated
  in place. The variant restarts at `min_instances` and autoscaling scales it back out, so expect reduced
  capacity during the rollout; deploy outside peak hours.
- **Changing `instance_type`:** SageMaker rejects instance-type changes on an autoscaled variant. Deregister
  the scalable target first, then apply:

  ```bash
  cd terraform
  terraform destroy -target=aws_appautoscaling_policy.gpu_util -target=aws_appautoscaling_target.nim
  terraform apply
  ```

## Teardown

```bash
cd terraform && terraform destroy
```

The ECR repository is not force-deleted by default. Delete its images first, or set
`ecr_force_delete = true` (demo environments only). The NGC secret is scheduled for deletion with the
default 30-day recovery window.

## Security notes

- **NGC key:** stored only in Secrets Manager. Terraform creates the empty secret, `deploy.sh` writes the value
  and the container reads it at startup (`launch.sh` → `aws secretsmanager get-secret-value`). The key is not in
  Terraform state, and `DescribeModel` only shows the secret ARN. The execution role can read only that secret.
- **State:** `.gitignore` excludes `*.tfstate*`, `terraform.tfvars`, `*.auto.tfvars` and `.terraform/`. Use the
  encrypted S3 backend in `terraform/backend.tf.example` for anything shared or long-lived.
- **Encryption:** ECR and the secret use KMS (AWS-managed keys by default). Set `kms_key_arn` to use a
  customer-managed key; the execution role then gets `kms:Decrypt` on that key only. `ml.g5` instances use
  hardware-encrypted NVMe instance storage, so no volume KMS key is set.
- **IAM:** the execution role can pull from this ECR repo, read the NGC secret and write to
  `/aws/sagemaker/Endpoints/nim-demo` only.
- **Network:** the endpoint is not publicly reachable: callers need `sagemaker:InvokeEndpoint` IAM permission
  (SigV4). By default the container has unrestricted outbound access, because NIM downloads weights from NGC at
  boot. To restrict it, set `subnet_ids` and `security_group_ids` to private subnets whose egress goes through a
  NAT with an allow-list (`*.ngc.nvidia.com`, `*.nvcr.io`) plus a Secrets Manager VPC endpoint. Pre-staging the
  weights in S3 (`model_data_url`) and enabling network isolation would remove the outbound need entirely; that
  is not implemented here.
- **Supply chain:** Caddy (`caddy:2.8.4`) and the AWS CLI (`amazon/aws-cli:2.17.0`) are pinned to exact versions
  and NIM to the digest resolved at build time. The image build fails if the NIM start command is not
  executable.

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
