# SageMaker-compatible wrapper around the NVIDIA NIM LLM container.
# SageMaker runs `docker run <image> serve` and expects GET /ping and
# POST /invocations on port 8080; NIM serves an OpenAI API on port 8000.
# The `serve` entrypoint starts NIM and a small stdlib proxy that bridges the two.
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
FROM ${NIM_IMAGE}

ENV NIM_SERVER_PORT=8000 \
    SAGEMAKER_PORT=8080

COPY --chmod=755 serve /usr/local/bin/serve
COPY --chmod=644 sagemaker_proxy.py /opt/sagemaker/sagemaker_proxy.py

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/serve"]
