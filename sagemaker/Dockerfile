# SageMaker-compatible wrapper around an NVIDIA NIM LLM image.
#
# SageMaker real-time endpoints require the container to listen on :8080 and
# serve GET /ping (health) and POST /invocations (inference). NIM serves an
# OpenAI-compatible API on :8000, so a tiny Caddy reverse proxy maps:
#   /ping        -> /v1/health/ready
#   /invocations -> /v1/chat/completions
#
# NIM_IMAGE has no default on purpose: scripts/deploy.sh resolves the NIM tag
# to an immutable digest (image@sha256:...) and passes it in, so every build of
# a given digest is reproducible.
ARG NIM_IMAGE
ARG CADDY_IMAGE=caddy:2.8.4
# AWS CLI is used by launch.sh to read the NGC key from Secrets Manager.
ARG AWSCLI_IMAGE=amazon/aws-cli:2.17.0
# User the upstream NIM image runs as (deploy.sh reads it via `docker inspect`).
ARG NIM_UID=1000
# Start command of the upstream NIM image (deploy.sh reads Entrypoint + Cmd).
ARG NIM_START_CMD="/opt/nvidia/nvidia_entrypoint.sh /opt/nim/start-server.sh"

FROM ${CADDY_IMAGE} AS caddy
FROM ${AWSCLI_IMAGE} AS awscli

FROM ${NIM_IMAGE}
ARG NIM_UID
ARG NIM_START_CMD
USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=awscli /usr/local/aws-cli /usr/local/aws-cli
COPY Caddyfile /etc/caddy/Caddyfile
COPY launch.sh /usr/local/bin/launch.sh
# The start-command check fails the build (not a 30-minute SageMaker health
# check) if the assumptions about the upstream image are wrong.
RUN ln -sf /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
 && chmod 0755 /usr/local/bin/launch.sh /usr/local/bin/caddy \
 && for f in ${NIM_START_CMD}; do case "$f" in /*) test -x "$f" || { echo "NIM start command not executable: $f" >&2; exit 1; } ;; esac; done \
 && caddy version >/dev/null \
 && aws --version >/dev/null

ENV NIM_START_CMD="${NIM_START_CMD}"
# Drop back to the non-root NIM user.
USER ${NIM_UID}
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/launch.sh"]
