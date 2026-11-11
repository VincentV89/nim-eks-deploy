# SageMaker-compatible wrapper around the NVIDIA NIM container.
#
# SageMaker hosting requires the container to listen on :8080 and serve
#   GET  /ping         -> health check
#   POST /invocations  -> inference
# NIM serves an OpenAI-compatible API on :8000, so a tiny Caddy reverse proxy
# maps the SageMaker contract onto the NIM routes.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY --chmod=0755 serve.sh /opt/sagemaker/serve.sh

ENV NIM_SERVER_PORT=8000
EXPOSE 8080

# SageMaker starts the container as `docker run <image> serve`; the extra arg is ignored.
ENTRYPOINT ["/opt/sagemaker/serve.sh"]
