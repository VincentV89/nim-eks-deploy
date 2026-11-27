# SageMaker-compatible wrapper around the NVIDIA NIM container.
#
# SageMaker real-time endpoints require the container to serve
#   GET  /ping         -> health check
#   POST /invocations  -> inference
# on port 8080. NIM serves an OpenAI-compatible API on port 8000, so we
# put a tiny Caddy reverse proxy in front of it to translate the routes.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2.8.4

# hadolint ignore=DL3006
FROM ${CADDY_IMAGE} AS caddy

# hadolint ignore=DL3006
FROM ${NIM_IMAGE}

# COPY writes as root regardless of USER, so the image keeps NIM's default
# (non-root) runtime user. --chmod requires BuildKit (default in Docker 23+).
COPY --from=caddy --chmod=0755 /usr/bin/caddy /usr/local/bin/caddy
COPY --chmod=0644 Caddyfile /etc/caddy/Caddyfile
COPY --chmod=0755 serve.sh /usr/local/bin/serve

# NIM listens internally on 8000; SageMaker talks to Caddy on 8080.
ENV NIM_SERVER_PORT=8000
EXPOSE 8080

# SageMaker starts the container as `docker run <image> serve`.
ENTRYPOINT ["/usr/local/bin/serve"]
