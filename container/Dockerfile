# SageMaker-compatible wrapper around the NVIDIA NIM image.
#
# SageMaker real-time endpoints require the container to listen on :8080 and
# serve GET /ping and POST /invocations. NIM serves an OpenAI-compatible API on
# :8000, so a tiny Caddy reverse proxy maps the SageMaker contract onto it:
#   GET  /ping         -> /v1/health/ready
#   POST /invocations  -> /v1/chat/completions
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY serve /opt/sagemaker/serve

ENV NIM_SERVER_PORT=8000
EXPOSE 8080

# SageMaker runs `docker run <image> serve`; the entrypoint ignores that arg.
ENTRYPOINT ["/opt/sagemaker/serve"]
