# Thin SageMaker adapter on top of the stock NVIDIA NIM image.
#
# SageMaker hosting contract: the container must listen on :8080 and serve
#   GET  /ping         -> health check
#   POST /invocations  -> inference
# NIM natively serves an OpenAI-compatible API on :8000, so Caddy maps the
# SageMaker routes onto NIM's /v1/health/ready and /v1/chat/completions.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM ${NIM_IMAGE}

ARG CADDY_VERSION=2.8.4
ARG AWSCLI_VERSION=2.17.0

USER root

WORKDIR /tmp/build
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates unzip \
 && curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin caddy \
 && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" -o awscli.zip \
 && unzip -q awscli.zip \
 && ./aws/install \
 && apt-get clean
WORKDIR /

COPY Caddyfile /opt/sagemaker/Caddyfile
COPY launch.sh /opt/sagemaker/launch.sh
RUN chmod 0755 /opt/sagemaker/launch.sh

EXPOSE 8080
ENTRYPOINT ["/opt/sagemaker/launch.sh"]
