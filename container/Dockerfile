# SageMaker-compatible wrapper around the NVIDIA NIM image.
#
# SageMaker hosting contract: the container is started with `serve`, must listen
# on :8080 and answer GET /ping (health) and POST /invocations (inference).
# NIM serves an OpenAI-compatible API on :8000, so a tiny Caddy reverse proxy
# maps the SageMaker routes onto NIM's routes.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --chmod=0755 serve /usr/local/bin/serve
COPY --chmod=0644 Caddyfile /etc/caddy/Caddyfile

ENV NIM_SERVER_PORT=8000
EXPOSE 8080

# SageMaker runs `docker run <image> serve`; ENTRYPOINT ignores the extra arg.
ENTRYPOINT ["/usr/local/bin/serve"]
