"""
Load test for NIM on SageMaker — fires concurrent chat completions at the endpoint
to trigger GPU autoscaling.
Usage: python load_test.py <endpoint-name> --rps 20 --duration 60 [--region us-east-1]
"""
import argparse
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

PAYLOAD = {
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
}


def send_request(client, endpoint, body, stats, lock):
    t0 = time.monotonic()
    try:
        r = client.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=body)
        r["Body"].read()
        latency = time.monotonic() - t0
        with lock:
            stats["ok"] += 1
            stats["latencies"].append(latency)
    except Exception as e:  # noqa: BLE001 - count every failure, show the first few
        with lock:
            stats["err"] += 1
            if stats["err"] <= 3:
                print(f"error: {e}")


def main(endpoint, rps, duration, region):
    # One shared client (thread-safe); size the pool for the expected concurrency.
    client = boto3.client(
        "sagemaker-runtime",
        region_name=region,
        config=Config(max_pool_connections=max(10, rps * 10), read_timeout=120, retries={"max_attempts": 0}),
    )
    body = json.dumps(PAYLOAD)
    stats = {"ok": 0, "err": 0, "latencies": []}
    lock = threading.Lock()
    interval = 1.0 / rps

    start = time.monotonic()
    end = start + duration
    with ThreadPoolExecutor(max_workers=max(10, rps * 10)) as pool:
        next_send = start
        while next_send < end:
            pool.submit(send_request, client, endpoint, body, stats, lock)
            next_send += interval
            time.sleep(max(0.0, next_send - time.monotonic()))
    elapsed = time.monotonic() - start

    lats = sorted(stats["latencies"])
    print(f"\n{'='*50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/elapsed:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("endpoint", help="SageMaker endpoint name, e.g. nim-demo")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    p.add_argument("--region", default=None, help="AWS region (default: from AWS config/env)")
    args = p.parse_args()
    main(args.endpoint, args.rps, args.duration, args.region)
