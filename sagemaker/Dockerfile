# SageMaker adapter for NVIDIA NIM.
#
# SageMaker hosting requires the container to:
#   * be pulled from ECR (scripts/deploy.sh mirrors the NIM image there),
#   * listen on :8080 and answer GET /ping and POST /invocations.
# NIM serves an OpenAI-compatible API on :8000, so we add a tiny Caddy reverse
# proxy in front of it and an entrypoint that fetches the NGC key from
# Secrets Manager before starting NIM.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}
# Original NIM start command (entrypoint + cmd of the base image). deploy.sh
# fills this in via `docker inspect` so we never have to hardcode it.
ARG NIM_START_CMD
ENV NIM_START_CMD=${NIM_START_CMD} \
    NIM_SERVER_PORT=8000

USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
RUN python3 -m pip install --no-cache-dir --target /opt/sm-adapter/lib boto3
COPY Caddyfile serve.sh get_secret.py /opt/sm-adapter/
RUN chmod +x /opt/sm-adapter/serve.sh

EXPOSE 8080
ENTRYPOINT ["/opt/sm-adapter/serve.sh"]
