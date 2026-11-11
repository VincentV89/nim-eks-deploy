# SageMaker-compatible wrapper around the NVIDIA NIM image.
# SageMaker requires the container to answer GET /ping and POST /invocations on
# port 8080; NIM serves its OpenAI-compatible API on port 8000. Caddy bridges them.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
COPY serve /usr/local/bin/serve
RUN chmod 755 /usr/local/bin/serve /usr/local/bin/caddy

ENV NIM_SERVER_PORT=8000
EXPOSE 8080
# SageMaker launches the container as `docker run <image> serve`
ENTRYPOINT ["/usr/local/bin/serve"]
