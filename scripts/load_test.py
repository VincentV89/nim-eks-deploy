"""
Load test for the NIM SageMaker endpoint — fires concurrent chat completions to
trigger GPU-utilization autoscaling.
Usage: python load_test.py <endpoint-name> --rps 20 --duration 60 [--region us-east-1]
"""
import argparse, json, threading, time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

PAYLOAD = json.dumps({
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
})


def main(endpoint, region, rps, duration):
    client = boto3.client(
        "sagemaker-runtime",
        region_name=region,
        config=Config(max_pool_connections=max(10, rps * 4), retries={"max_attempts": 0}, read_timeout=120),
    )
    stats = {"ok": 0, "err": 0, "latencies": []}
    lock = threading.Lock()

    def send_request():
        t0 = time.monotonic()
        try:
            r = client.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=PAYLOAD)
            r["Body"].read()
            with lock:
                stats["ok"] += 1
                stats["latencies"].append(time.monotonic() - t0)
        except Exception:
            with lock:
                stats["err"] += 1

    interval = 1.0 / rps
    end = time.monotonic() + duration
    with ThreadPoolExecutor(max_workers=max(10, rps * 4)) as pool:
        while time.monotonic() < end:
            pool.submit(send_request)
            time.sleep(interval)

    lats = sorted(stats["latencies"])
    print(f"\n{'='*50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/duration:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("endpoint", help="SageMaker endpoint name, e.g. nim-demo")
    p.add_argument("--region", default=None, help="AWS region (defaults to your AWS config)")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    args = p.parse_args()
    main(args.endpoint, args.region, args.rps, args.duration)
