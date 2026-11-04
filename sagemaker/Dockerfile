# Wraps an NVIDIA NIM image so it satisfies the SageMaker hosting contract:
#   - listens on :8080
#   - GET  /ping         -> NIM /v1/health/ready
#   - POST /invocations  -> NIM /v1/chat/completions (or /v1/completions)
ARG NIM_IMAGE=nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3
FROM ${NIM_IMAGE}

USER root
# boto3 is used only to fetch the NGC API key from Secrets Manager at startup
RUN python3 -m pip install --no-cache-dir boto3
COPY --chmod=755 launch.sh /opt/sagemaker/launch.sh
COPY --chmod=644 proxy.py  /opt/sagemaker/proxy.py

EXPOSE 8080
ENTRYPOINT ["/opt/sagemaker/launch.sh"]
