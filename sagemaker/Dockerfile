# NVIDIA NIM wrapped for SageMaker real-time inference.
#
# SageMaker requires the container to listen on :8080 and serve GET /ping and
# POST /invocations. NIM serves an OpenAI-compatible API on :8000, so a small
# Caddy reverse proxy maps one onto the other (see Caddyfile).
#
# Build via scripts/deploy.sh, which passes NIM_IMAGE and NIM_USER.

ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
ARG CADDY_IMAGE=caddy:2.8.4

FROM ${CADDY_IMAGE} AS caddy

# Pure-Python boto3, used only by get_secret.py to read the NGC key at startup.
FROM python:3.12-slim AS shim-deps
RUN pip install --no-cache-dir --target /opt/shim/lib boto3==1.35.*

FROM ${NIM_IMAGE}

# Non-root user the NIM base image runs as (deploy.sh reads it with `docker inspect`).
# There is deliberately no default: the build fails rather than silently running as root.
ARG NIM_USER
USER root
# Compare only the user part so `0:0` / `root:root` forms are rejected too.
RUN u="${NIM_USER%%:*}"; if [ -z "${u}" ] || [ "${u}" = "root" ] || [ "${u}" = "0" ]; then \
      echo "NIM_USER build arg must name the NIM image's non-root user" >&2; exit 1; \
    fi

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=shim-deps /opt/shim/lib /opt/shim/lib
COPY Caddyfile get_secret.py /opt/shim/
COPY --chmod=0755 launch.sh /opt/shim/launch.sh

ENV NIM_SERVER_PORT=8000 \
    XDG_DATA_HOME=/tmp/caddy \
    XDG_CONFIG_HOME=/tmp/caddy

USER ${NIM_USER}
EXPOSE 8080
ENTRYPOINT ["/opt/shim/launch.sh"]
CMD ["serve"]
