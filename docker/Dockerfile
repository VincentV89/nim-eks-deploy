# SageMaker-compatible wrapper around the NVIDIA NIM container.
#
# SageMaker real-time endpoints require the container to:
#   * listen on port 8080
#   * answer GET  /ping         (health check)
#   * answer POST /invocations  (inference)
# NIM serves an OpenAI-compatible API on port 8000, so we add a tiny Caddy
# reverse proxy that maps the SageMaker contract onto the NIM API.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2.8

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY entrypoint.sh /opt/sagemaker/entrypoint.sh
RUN chmod 0755 /opt/sagemaker/entrypoint.sh

# NIM's OpenAI-compatible server stays on 8000; Caddy fronts it on 8080.
ENV NIM_SERVER_PORT=8000
EXPOSE 8080

ENTRYPOINT ["/opt/sagemaker/entrypoint.sh"]
