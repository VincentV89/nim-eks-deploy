# SageMaker-compatible wrapper around an NVIDIA NIM LLM image.
#
# SageMaker real-time endpoints require the container to serve on :8080 with
#   GET  /ping         -> health check
#   POST /invocations  -> inference
# NIM serves an OpenAI-compatible API on :8000, so Caddy reverse-proxies
#   /ping        -> /v1/health/ready
#   /invocations -> /v1/chat/completions
# and everything else (e.g. /v1/models) is passed through unchanged.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_VERSION=2.8.4

FROM caddy:${CADDY_VERSION}-alpine AS caddy

FROM ${NIM_IMAGE}
ARG NIM_USER=1000

USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /opt/sagemaker/Caddyfile
COPY launch.sh fetch_secret.py /opt/sagemaker/
# boto3 is installed into an isolated path so it cannot clash with NIM's deps.
RUN pip install --no-cache-dir --target /opt/sagemaker/py boto3==1.35.* \
 && chmod 0755 /opt/sagemaker/launch.sh \
 && caddy validate --config /opt/sagemaker/Caddyfile --adapter caddyfile

USER ${NIM_USER}
EXPOSE 8080
# SageMaker runs `docker run <image> serve`; launch.sh ignores the argument.
ENTRYPOINT ["/opt/sagemaker/launch.sh"]
