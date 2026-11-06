# NIM container adapted for the Amazon SageMaker real-time inference contract.
#
# SageMaker requires the container to listen on port 8080 and serve:
#   GET  /ping         -> health check
#   POST /invocations  -> inference
# NIM serves an OpenAI-compatible API on port 8000, so a tiny Caddy reverse
# proxy maps the SageMaker routes onto the NIM routes (see Caddyfile).
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest

FROM caddy:2 AS caddy

FROM ${NIM_IMAGE}

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --chmod=0644 Caddyfile /opt/sagemaker/Caddyfile
COPY --chmod=0755 serve.sh /opt/sagemaker/serve.sh

EXPOSE 8080

# SageMaker starts the container as `docker run <image> serve`; serve.sh
# ignores its arguments, so the override is harmless.
ENTRYPOINT ["/opt/sagemaker/serve.sh"]
CMD ["serve"]
