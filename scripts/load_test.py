"""
Load test for NIM on SageMaker — fires concurrent chat completions at the endpoint
to drive GPU utilization and trigger endpoint autoscaling.

Usage: python load_test.py <endpoint-name> [--region us-east-1] [--rps 5] [--duration 120]
Requires: pip install boto3
"""
import argparse, collections, json, threading, time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config


def make_payload(model):
    return json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
        "max_tokens": 100,
    })


def main(endpoint, region, rps, duration, model, workers):
    client = boto3.client(
        "sagemaker-runtime", region_name=region,
        config=Config(max_pool_connections=workers, retries={"max_attempts": 0}, read_timeout=120),
    )
    body = make_payload(model)
    lock = threading.Lock()
    stats = {"ok": 0, "latencies": [], "errors": collections.Counter()}

    def send():
        t0 = time.monotonic()
        try:
            r = client.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=body)
            r["Body"].read()
            with lock:
                stats["ok"] += 1
                stats["latencies"].append(time.monotonic() - t0)
        except Exception as e:  # count by error type so throttling/model errors are visible
            code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
            with lock:
                stats["errors"][code] += 1

    interval = 1.0 / rps
    start = time.monotonic()
    end = start + duration
    with ThreadPoolExecutor(max_workers=workers) as pool:
        next_t = start
        while next_t < end:
            pool.submit(send)
            next_t += interval
            time.sleep(max(0.0, next_t - time.monotonic()))
    elapsed = time.monotonic() - start

    lats = sorted(stats["latencies"])
    n_err = sum(stats["errors"].values())
    print(f"\n{'=' * 50}")
    print(f"Requests:   {stats['ok']} ok / {n_err} errors")
    for code, n in stats["errors"].most_common(5):
        print(f"  {code}: {n}")
    if lats:
        pct = lambda q: lats[min(len(lats) - 1, int(len(lats) * q))]
        print(f"Latency:    p50={pct(0.5):.2f}s  p95={pct(0.95):.2f}s  p99={pct(0.99):.2f}s")
        print(f"Throughput: {stats['ok'] / elapsed:.1f} req/s over {elapsed:.0f}s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("endpoint", help="SageMaker endpoint name (terraform output endpoint_name)")
    p.add_argument("--region", default=None, help="AWS region (defaults to your AWS config)")
    p.add_argument("--rps", type=float, default=5, help="Requests per second (> 0)")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    p.add_argument("--model", default="meta/llama-3.1-8b-instruct", help="terraform output served_model_name")
    p.add_argument("--workers", type=int, default=64, help="Max concurrent in-flight requests")
    a = p.parse_args()
    if a.rps <= 0 or a.duration <= 0:
        p.error("--rps and --duration must be > 0")
    main(a.endpoint, a.region, a.rps, a.duration, a.model, a.workers)
