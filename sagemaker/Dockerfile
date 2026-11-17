# NIM image adapted for the SageMaker hosting contract:
#   - listen on :8080
#   - GET  /ping         -> health check
#   - POST /invocations  -> inference
# A Caddy reverse proxy maps those routes onto NIM's OpenAI-compatible API,
# which keeps running unchanged on :8000 inside the container.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM ${NIM_IMAGE}

ARG CADDY_VERSION=2.8.4

USER root

# Caddy (static binary) for the /ping + /invocations shim.
# boto3 is used by launch.sh to read the NGC API key from Secrets Manager.
RUN set -eux; \
    curl -fsSL -o /tmp/caddy.tar.gz \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
    rm /tmp/caddy.tar.gz; \
    chmod 0755 /usr/local/bin/caddy; \
    python3 -m pip install --no-cache-dir boto3

COPY Caddyfile /opt/sagemaker/Caddyfile
COPY launch.sh /opt/sagemaker/launch.sh
RUN chmod 0755 /opt/sagemaker/launch.sh

EXPOSE 8080

# SageMaker starts the container with `docker run <image> serve`;
# launch.sh ignores the argument.
ENTRYPOINT ["/opt/sagemaker/launch.sh"]
