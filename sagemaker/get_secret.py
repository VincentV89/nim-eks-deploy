"""Print a Secrets Manager secret value (used by serve.sh to load NGC_API_KEY)."""
import os
import sys

sys.path.insert(0, "/opt/sm-adapter/lib")
import boto3  # noqa: E402

client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION"))
sys.stdout.write(client.get_secret_value(SecretId=sys.argv[1])["SecretString"])
