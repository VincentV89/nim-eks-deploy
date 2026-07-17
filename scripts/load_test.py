"""
Load test for NIM on SageMaker -- fires concurrent inference requests to trigger auto scaling.
Usage: python load_test.py --endpoint-name <ENDPOINT_NAME> --region us-east-1 --rps 10 --duration 60
"""
import argparse
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3

PAYLOAD = json.dumps({
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
})


def send_request(client, endpoint_name, stats):
    """Invoke the SageMaker endpoint and record latency."""
    t0 = time.monotonic()
    try:
        response = client.invoke_endpoint(
            EndpointName=endpoint_name,
            ContentType="application/json",
            Body=PAYLOAD,
        )
        _ = response["Body"].read()
        latency = time.monotonic() - t0
        stats["ok"] += 1
        stats["latencies"].append(latency)
    except Exception:
        stats["err"] += 1


def main(endpoint_name, region, rps, duration):
    client = boto3.client("sagemaker-runtime", region_name=region)
    stats = {"ok": 0, "err": 0, "latencies": []}
    interval = 1.0 / rps
    end_time = time.monotonic() + duration
    futures = []

    print(f"Load testing endpoint '{endpoint_name}' at {rps} req/s for {duration}s ...")

    with ThreadPoolExecutor(max_workers=min(rps * 2, 200)) as executor:
        while time.monotonic() < end_time:
            futures.append(executor.submit(send_request, client, endpoint_name, stats))
            time.sleep(interval)
        # Wait for all in-flight requests to complete
        for f in as_completed(futures):
            pass

    lats = sorted(stats["latencies"])
    print(f"\n{'=' * 50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/duration:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Load test a SageMaker NIM endpoint")
    p.add_argument("--endpoint-name", required=True, help="SageMaker endpoint name")
    p.add_argument("--region", default="us-east-1", help="AWS region (default: us-east-1)")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    args = p.parse_args()
    main(args.endpoint_name, args.region, args.rps, args.duration)
