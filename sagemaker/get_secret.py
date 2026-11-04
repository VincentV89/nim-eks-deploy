"""Print the NGC API key stored in Secrets Manager (secret ID in $NGC_SECRET_ID).

Runs inside the SageMaker container with the endpoint's execution role, so the
key never appears in the SageMaker model definition or in Terraform state.
"""
import os
import sys

import boto3


def main() -> int:
    secret_id = os.environ.get("NGC_SECRET_ID")
    if not secret_id:
        print("NGC_SECRET_ID is not set", file=sys.stderr)
        return 1
    # Secret ARNs look like arn:aws:secretsmanager:<region>:<account>:secret:<name>
    region = secret_id.split(":")[3] if secret_id.startswith("arn:") else None
    client = boto3.client("secretsmanager", region_name=region)
    value = client.get_secret_value(SecretId=secret_id)["SecretString"].strip()
    if not value:
        print(f"Secret {secret_id} is empty", file=sys.stderr)
        return 1
    sys.stdout.write(value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
