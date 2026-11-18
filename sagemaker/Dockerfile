# SageMaker-compatible wrapper around the NVIDIA NIM image.
#
# SageMaker hosting requires the container to:
#   * listen on port 8080
#   * answer GET /ping (health) and POST /invocations (inference)
#   * start when invoked as `docker run <image> serve`
# NIM serves an OpenAI-compatible API on port 8000, so a small Caddy reverse
# proxy maps the SageMaker contract onto the NIM routes.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY serve /opt/sagemaker/serve

EXPOSE 8080
ENTRYPOINT ["/opt/sagemaker/serve"]
