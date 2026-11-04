"""
Load test for NIM on SageMaker — fires concurrent chat completions at the
endpoint to trigger GPU-utilization autoscaling.
Usage: python load_test.py <endpoint-name> --region us-east-1 --rps 20 --duration 60
Requires: pip install boto3
"""
import argparse
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

PAYLOAD = json.dumps({
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
})


def send_request(client, endpoint, stats, lock):
    t0 = time.monotonic()
    try:
        r = client.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=PAYLOAD)
        r["Body"].read()
        latency = time.monotonic() - t0
        with lock:
            stats["ok"] += 1
            stats["latencies"].append(latency)
    except Exception as e:  # noqa: BLE001 — count every failure
        with lock:
            stats["err"] += 1
            stats["last_err"] = repr(e)


def main(endpoint, region, rps, duration):
    workers = max(rps * 30, 32)  # enough in-flight slots for slow generations
    client = boto3.client(
        "sagemaker-runtime",
        region_name=region,
        config=Config(max_pool_connections=workers, read_timeout=120, retries={"max_attempts": 0}),
    )
    stats = {"ok": 0, "err": 0, "latencies": [], "last_err": None}
    lock = threading.Lock()
    interval = 1.0 / rps
    start = time.monotonic()
    end = start + duration

    with ThreadPoolExecutor(max_workers=workers) as pool:
        while time.monotonic() < end:
            pool.submit(send_request, client, endpoint, stats, lock)
            time.sleep(interval)
    elapsed = time.monotonic() - start

    lats = sorted(stats["latencies"])
    print(f"\n{'='*50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if stats["last_err"]:
        print(f"Last error: {stats['last_err']}")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/elapsed:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("endpoint", help="SageMaker endpoint name, e.g. nim-demo")
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    args = p.parse_args()
    main(args.endpoint, args.region, args.rps, args.duration)
