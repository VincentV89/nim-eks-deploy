# NIM image adapted for the SageMaker hosting contract.
#
# SageMaker sends traffic to port 8080 on /ping (health) and /invocations
# (inference). NIM serves an OpenAI-compatible API on port 8000, so a small
# Caddy reverse proxy maps the SageMaker routes onto the NIM routes.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM ${NIM_IMAGE}

ARG CADDY_VERSION=2.8.4
USER root
RUN set -eux; \
    curl -fsSL -o /tmp/caddy.tar.gz \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
    rm /tmp/caddy.tar.gz; \
    caddy version

COPY Caddyfile /opt/sagemaker/Caddyfile
COPY serve.sh /opt/sagemaker/serve.sh
RUN chmod +x /opt/sagemaker/serve.sh

EXPOSE 8080
# SageMaker runs the container as `docker run <image> serve`; the arg is ignored.
ENTRYPOINT ["/opt/sagemaker/serve.sh"]
