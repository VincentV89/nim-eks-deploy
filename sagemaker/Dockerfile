# SageMaker-compatible wrapper around the NVIDIA NIM container.
#
# SageMaker hosting requires the container to listen on :8080 and expose
# GET /ping (health) and POST /invocations (inference). NIM serves an
# OpenAI-compatible API on :8000, so a tiny Caddy reverse proxy maps:
#   /ping         -> /v1/health/ready
#   /invocations  -> /v1/chat/completions
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM caddy:2 AS caddy

ARG NIM_IMAGE
FROM ${NIM_IMAGE}

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY serve /usr/local/bin/serve

USER root
RUN chmod 0755 /usr/local/bin/serve /usr/local/bin/caddy
USER 1000

EXPOSE 8080
# SageMaker starts the container as `docker run <image> serve`.
ENTRYPOINT ["/usr/local/bin/serve"]
