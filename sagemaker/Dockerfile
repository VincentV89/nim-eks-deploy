# SageMaker adapter for an NVIDIA NIM LLM image.
#
# SageMaker real-time endpoints send health checks to GET /ping and requests to
# POST /invocations on port 8080. NIM serves an OpenAI-compatible API on port 8000,
# so a tiny Caddy reverse proxy maps the SageMaker contract onto NIM:
#   GET  /ping        -> GET  /v1/health/ready
#   POST /invocations -> POST /v1/chat/completions
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}
USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY entrypoint.sh /opt/sagemaker/entrypoint.sh
RUN chmod 0755 /opt/sagemaker/entrypoint.sh

ENV NIM_SERVER_PORT=8000
EXPOSE 8080
# SageMaker starts the container as `docker run <image> serve`; the arg is ignored.
ENTRYPOINT ["/opt/sagemaker/entrypoint.sh"]
