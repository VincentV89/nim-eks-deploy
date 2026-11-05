"""
Load test for NIM on SageMaker — fires concurrent chat completions at the
endpoint to trigger GPU autoscaling.
Usage: python load_test.py <ENDPOINT_NAME> --region us-east-1 --rps 20 --duration 60
"""
import argparse, asyncio, json, time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

PAYLOAD = json.dumps({
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
})

def invoke(client, endpoint):
    # Timer starts here (inside the worker thread), so latency excludes the
    # time a request spent queued in the thread pool.
    t0 = time.monotonic()
    r = client.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=PAYLOAD)
    r["Body"].read()
    return time.monotonic() - t0

def error_reason(exc):
    # botocore ClientError -> service error code (ThrottlingException, ModelError, ...)
    code = getattr(exc, "response", {}).get("Error", {}).get("Code")
    return code or type(exc).__name__

async def send_request(loop, pool, client, endpoint, stats):
    try:
        latency = await loop.run_in_executor(pool, invoke, client, endpoint)
        stats["ok"] += 1
        stats["latencies"].append(latency)
    except Exception as exc:
        stats["err"] += 1
        stats["errors"][error_reason(exc)] += 1

async def main(endpoint, region, rps, duration, concurrency):
    stats = {"ok": 0, "err": 0, "latencies": [], "errors": Counter()}
    interval = 1.0 / rps
    client = boto3.client(
        "sagemaker-runtime", region_name=region,
        config=Config(max_pool_connections=concurrency, retries={"max_attempts": 0}, read_timeout=120),
    )
    loop = asyncio.get_running_loop()
    start = time.monotonic()
    end = start + duration

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        tasks = []
        while time.monotonic() < end:
            tasks.append(asyncio.create_task(send_request(loop, pool, client, endpoint, stats)))
            await asyncio.sleep(interval)
        await asyncio.gather(*tasks)
    elapsed = time.monotonic() - start

    lats = sorted(stats["latencies"])
    print(f"\n{'='*50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    for reason, n in stats["errors"].most_common():
        print(f"  {reason}: {n}")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/elapsed:.1f} req/s (over {elapsed:.1f}s)")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("endpoint", help="SageMaker endpoint name, e.g. nim-demo")
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    p.add_argument("--concurrency", type=int, default=64, help="Max in-flight requests")
    args = p.parse_args()
    asyncio.run(main(args.endpoint, args.region, args.rps, args.duration, args.concurrency))
