# SageMaker-compatible wrapper around an NVIDIA NIM LLM image.
#
# SageMaker real-time endpoints require the container to listen on :8080 and
# serve GET /ping (health) and POST /invocations (inference). NIM serves an
# OpenAI-compatible API on :8000, so a tiny Caddy reverse proxy maps:
#   /ping        -> /v1/health/ready
#   /invocations -> /v1/chat/completions
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2
# UID the upstream NIM image runs as (non-root).
ARG NIM_UID=1000

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
ARG NIM_UID
USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
COPY launch.sh /usr/local/bin/launch.sh
RUN chmod 0755 /usr/local/bin/launch.sh /usr/local/bin/caddy

# Drop back to the non-root NIM user.
USER ${NIM_UID}
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/launch.sh"]
