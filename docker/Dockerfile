# SageMaker adapter for NVIDIA NIM.
# SageMaker real-time endpoints require the container to serve GET /ping and
# POST /invocations on port 8080. NIM serves an OpenAI-compatible API on 8000,
# so a small Caddy reverse proxy maps the SageMaker contract onto NIM.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2

FROM ${CADDY_IMAGE} AS caddy

FROM ${NIM_IMAGE}
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY serve.sh /opt/sagemaker/serve.sh

ENV NIM_SERVER_PORT=8000 \
    XDG_DATA_HOME=/tmp/caddy \
    XDG_CONFIG_HOME=/tmp/caddy

EXPOSE 8080
# SageMaker starts the container as `docker run <image> serve`; serve.sh ignores args.
ENTRYPOINT ["/bin/bash", "/opt/sagemaker/serve.sh"]
