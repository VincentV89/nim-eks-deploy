# SageMaker-compatible wrapper around an NVIDIA NIM LLM image.
#
# SageMaker requires the container to:
#   * accept `serve` as its argument (`docker run <image> serve`)
#   * listen on port 8080 and answer GET /ping and POST /invocations
# NIM serves an OpenAI-compatible API on port 8000, so a Caddy reverse proxy
# maps the SageMaker contract onto it.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2-alpine AS caddy

FROM ${NIM_IMAGE}
USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
COPY serve /usr/local/bin/serve
RUN chmod 0755 /usr/local/bin/serve /usr/local/bin/caddy

ENV NIM_SERVER_PORT=8000
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/serve"]
