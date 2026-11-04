# SageMaker-compatible wrapper around an NVIDIA NIM LLM container.
#
# SageMaker real-time endpoints require the container to listen on :8080 and
# serve GET /ping and POST /invocations. NIM serves an OpenAI-compatible API on
# :8000, so we add a tiny Caddy reverse proxy that maps the SageMaker contract
# onto NIM's routes. NIM itself runs unmodified via its original entrypoint.
#
# Build args are filled in by scripts/deploy.sh from `docker inspect` of the
# NIM image, so we never hard-code NIM's internal entrypoint or user.

ARG NIM_IMAGE
ARG CADDY_IMAGE=caddy:2.8-alpine
ARG AWS_CLI_IMAGE=amazon/aws-cli:2.18.0

FROM ${CADDY_IMAGE} AS caddy
FROM ${AWS_CLI_IMAGE} AS awscli

FROM ${NIM_IMAGE}
ARG NIM_START_CMD
ARG NIM_USER=root

USER root
# Caddy is a static binary; the AWS CLI v2 bundle is self-contained (only needs glibc).
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=awscli /usr/local/aws-cli /usr/local/aws-cli
RUN ln -sf /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws
COPY --chmod=0755 launch.sh /opt/sagemaker/launch.sh
COPY --chmod=0644 Caddyfile /opt/sagemaker/Caddyfile

ENV NIM_START_CMD=${NIM_START_CMD} \
    NIM_SERVER_PORT=8000 \
    XDG_DATA_HOME=/tmp/caddy-data \
    XDG_CONFIG_HOME=/tmp/caddy-config

# Drop back to the NIM image's original (non-root) user.
USER ${NIM_USER}
EXPOSE 8080

# SageMaker starts the container as `docker run <image> serve`; launch.sh ignores args.
ENTRYPOINT ["/opt/sagemaker/launch.sh"]
