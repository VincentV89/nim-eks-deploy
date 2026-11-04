# SageMaker-compatible wrapper around an NVIDIA NIM LLM image.
#
# SageMaker requires the container to:
#   * accept `serve` as its argument (`docker run <image> serve`)
#   * listen on port 8080 and answer GET /ping and POST /invocations
# NIM serves an OpenAI-compatible API on port 8000, so a Caddy reverse proxy
# maps the SageMaker contract onto it.
#
# Images are pinned to explicit versions for reproducible builds; bump them
# deliberately (scripts/deploy.sh passes NIM_IMAGE through as a build arg).
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3
ARG CADDY_IMAGE=caddy:2.8.4-alpine

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
# Non-root UID the NIM image runs as (NIM images default to UID 1000).
ARG RUN_AS_UID=1000

# Root is only needed to install the shim files; the server runs unprivileged.
USER root
COPY --from=caddy --chmod=0755 /usr/bin/caddy /usr/local/bin/caddy
COPY --chmod=0644 Caddyfile /etc/caddy/Caddyfile
COPY --chmod=0755 serve /usr/local/bin/serve

ENV NIM_SERVER_PORT=8000 \
    XDG_CONFIG_HOME=/tmp/caddy/config \
    XDG_DATA_HOME=/tmp/caddy/data
EXPOSE 8080
USER ${RUN_AS_UID}
ENTRYPOINT ["/usr/local/bin/serve"]
