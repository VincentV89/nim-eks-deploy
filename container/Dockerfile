# SageMaker-compatible wrapper around an NVIDIA NIM image.
#
# SageMaker hosting requires the container to answer GET /ping and
# POST /invocations on port 8080. NIM serves an OpenAI-compatible API on 8000,
# so a tiny Caddy reverse proxy maps the SageMaker contract onto NIM:
#   GET  /ping        -> GET  /v1/health/ready
#   POST /invocations -> POST /v1/chat/completions
#
# Build with scripts/deploy.sh (it fills in NIM_IMAGE and NIM_CMD).
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM public.ecr.aws/amazonlinux/amazonlinux:2023 AS awscli
RUN dnf install -y unzip && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --install-dir /opt/aws-cli --bin-dir /opt/aws-cli/bin

FROM ${NIM_IMAGE}
# Original NIM ENTRYPOINT + CMD, captured by scripts/deploy.sh via `docker inspect`
ARG NIM_CMD
ENV NIM_CMD="${NIM_CMD}" \
    NIM_SERVER_PORT=8000 \
    XDG_DATA_HOME=/tmp/caddy \
    XDG_CONFIG_HOME=/tmp/caddy

USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=awscli /opt/aws-cli /opt/aws-cli
COPY Caddyfile /opt/sagemaker-shim/Caddyfile
COPY serve /opt/sagemaker-shim/serve
RUN chmod 0755 /opt/sagemaker-shim/serve && ln -sf /opt/aws-cli/bin/aws /usr/local/bin/aws

EXPOSE 8080
# SageMaker starts the container as `docker run <image> serve`
ENTRYPOINT ["/opt/sagemaker-shim/serve"]
