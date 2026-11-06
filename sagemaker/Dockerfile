# Wraps an NVIDIA NIM image so it satisfies the SageMaker hosting contract:
#   - listen on port 8080
#   - GET  /ping         -> health check
#   - POST /invocations  -> inference
# NIM keeps serving its OpenAI-compatible API on localhost:8000; a small
# stdlib-only proxy translates the SageMaker routes to it.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM ${NIM_IMAGE}

# Original NIM start command (entrypoint + cmd), captured by scripts/deploy.sh
# via `docker inspect` so we don't hard-code NIM-version-specific paths.
ARG NIM_START_CMD
ENV NIM_START_CMD=${NIM_START_CMD}

USER root
COPY serve.sh /opt/sagemaker/serve.sh
COPY proxy.py /opt/sagemaker/proxy.py
RUN chmod 0755 /opt/sagemaker/serve.sh

EXPOSE 8080
# SageMaker runs `docker run <image> serve`; serve.sh ignores its arguments.
ENTRYPOINT ["/opt/sagemaker/serve.sh"]
