# SageMaker-compatible wrapper around the NVIDIA NIM LLM container.
#
# SageMaker real-time endpoints expect the container to:
#   * start when invoked as `docker run <image> serve`
#   * listen on port 8080
#   * answer GET /ping (health) and POST /invocations (inference)
#
# NIM serves an OpenAI-compatible API on port 8000. A tiny Caddy reverse proxy
# maps the SageMaker contract onto NIM's endpoints (see Caddyfile).
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2-alpine AS caddy

FROM ${NIM_IMAGE}

USER root

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY launch.sh /opt/sagemaker/launch.sh
RUN chmod 0755 /opt/sagemaker/launch.sh \
 && (python3 -c "import boto3" 2>/dev/null || python3 -m pip install --no-cache-dir boto3)

EXPOSE 8080

ENTRYPOINT ["/opt/sagemaker/launch.sh"]
