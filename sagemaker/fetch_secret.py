"""Print a Secrets Manager secret value to stdout (used by launch.sh)."""
import os
import sys

import boto3


def main() -> None:
    arn = sys.argv[1]
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    client = boto3.client("secretsmanager", region_name=region)
    sys.stdout.write(client.get_secret_value(SecretId=arn)["SecretString"])


if __name__ == "__main__":
    main()
