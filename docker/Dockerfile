# SageMaker-compatible wrapper around an NVIDIA NIM container.
#
# SageMaker real-time endpoints require the container to:
#   - listen on port 8080
#   - answer GET  /ping         (health check)
#   - answer POST /invocations  (inference)
# NIM serves an OpenAI-compatible API on port 8000, so we add a tiny Caddy
# reverse proxy that maps the SageMaker contract onto the NIM API.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY --chmod=644 Caddyfile /opt/sagemaker/Caddyfile
COPY --chmod=755 launch.sh /opt/sagemaker/launch.sh

EXPOSE 8080
ENTRYPOINT ["/opt/sagemaker/launch.sh"]
