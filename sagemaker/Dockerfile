# SageMaker-compatible wrapper around the NVIDIA NIM container.
#
# SageMaker real-time endpoints require the container to serve:
#   GET  /ping         (health check)  on port 8080
#   POST /invocations  (inference)     on port 8080
# NIM serves an OpenAI-compatible API on port 8000, so we front it with Caddy
# and rewrite the SageMaker paths onto NIM's routes.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY serve.sh /opt/sagemaker/serve.sh

ENV NIM_SERVER_PORT=8000
EXPOSE 8080

# SageMaker launches the container as `docker run <image> serve`; extra args are ignored.
ENTRYPOINT ["/bin/bash", "/opt/sagemaker/serve.sh"]
