"""
Send a single chat completion to the NIM SageMaker endpoint.
Usage: python invoke.py --endpoint nim-demo [--region us-east-1] [--prompt "Hello"]
"""
import argparse, json, boto3


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", default="nim-demo", help="SageMaker endpoint name")
    p.add_argument("--region", default=None, help="AWS region (defaults to AWS config)")
    p.add_argument("--prompt", default="Hello")
    p.add_argument("--max-tokens", type=int, default=50)
    args = p.parse_args()

    client = boto3.client("sagemaker-runtime", region_name=args.region)
    body = {
        "model": "meta/llama-3.1-8b-instruct",
        "messages": [{"role": "user", "content": args.prompt}],
        "max_tokens": args.max_tokens,
    }
    resp = client.invoke_endpoint(
        EndpointName=args.endpoint,
        ContentType="application/json",
        Accept="application/json",
        Body=json.dumps(body),
    )
    print(json.dumps(json.loads(resp["Body"].read()), indent=2))


if __name__ == "__main__":
    main()
