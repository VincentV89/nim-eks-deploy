# SageMaker-compatible wrapper around an NVIDIA NIM LLM image.
#
# SageMaker real-time endpoints require the container to:
#   * listen on port 8080
#   * answer GET  /ping         (health check)
#   * answer POST /invocations  (inference)
# NIM serves an OpenAI-compatible API on port 8000 instead, so we add a tiny
# Caddy reverse proxy ("shim") that maps the SageMaker contract onto NIM:
#   /ping        -> /v1/health/ready
#   /invocations -> /v1/chat/completions
#
# Build (from repo root):
#   docker build --platform linux/amd64 \
#     --build-arg NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest \
#     -t nim-sagemaker container/
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}

# Caddy ships as a single static Go binary, so it runs on the NIM base image as-is.
COPY --from=caddy --chmod=755 /usr/bin/caddy /usr/local/bin/caddy
COPY --chmod=644 Caddyfile /opt/sagemaker-shim/Caddyfile
COPY --chmod=755 entrypoint.sh /opt/sagemaker-shim/entrypoint.sh

ENV NIM_SERVER_PORT=8000 \
    SAGEMAKER_PORT=8080 \
    XDG_CONFIG_HOME=/tmp/caddy/config \
    XDG_DATA_HOME=/tmp/caddy/data

EXPOSE 8080

# SageMaker launches the container as `docker run <image> serve`; the entrypoint
# ignores its arguments and starts both NIM and the shim.
ENTRYPOINT ["/opt/sagemaker-shim/entrypoint.sh"]
