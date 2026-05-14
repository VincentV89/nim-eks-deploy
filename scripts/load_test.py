"""
Load test for NVIDIA NIM on Amazon SageMaker.

Primary mode: invoke SageMaker endpoint via boto3 sagemaker-runtime.
Fallback mode: direct HTTP invocation via aiohttp (for URL-based testing).

Usage:
  python load_test.py --endpoint-name my-endpoint --rps 10 --duration 60
  python load_test.py http://localhost:8000 --rps 10 --duration 60
"""
import argparse
import asyncio
import json
import time
from concurrent.futures import ThreadPoolExecutor

PAYLOAD = {
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
}


def invoke_sagemaker(client, endpoint_name, stats):
    """Invoke a SageMaker endpoint using boto3."""
    t0 = time.monotonic()
    try:
        response = client.invoke_endpoint(
            EndpointName=endpoint_name,
            ContentType="application/json",
            Body=json.dumps(PAYLOAD),
        )
        response["Body"].read()
        latency = time.monotonic() - t0
        stats["ok"] += 1
        stats["latencies"].append(latency)
    except Exception:
        stats["err"] += 1


def run_sagemaker_load_test(endpoint_name, region, rps, duration):
    """Run load test against a SageMaker endpoint using ThreadPoolExecutor."""
    import boto3

    client = boto3.client("sagemaker-runtime", region_name=region)
    stats = {"ok": 0, "err": 0, "latencies": []}
    interval = 1.0 / rps
    end = time.monotonic() + duration

    futures = []
    with ThreadPoolExecutor(max_workers=rps * 2) as executor:
        while time.monotonic() < end:
            futures.append(executor.submit(invoke_sagemaker, client, endpoint_name, stats))
            time.sleep(interval)
        # Wait for all futures to complete
        for f in futures:
            f.result()

    print_stats(stats, duration)


async def send_request(session, url, stats):
    """Send a request to a direct HTTP endpoint."""
    t0 = time.monotonic()
    try:
        async with session.post(f"{url}/v1/chat/completions", json=PAYLOAD) as r:
            await r.read()
            latency = time.monotonic() - t0
            stats["ok"] += 1
            stats["latencies"].append(latency)
    except Exception:
        stats["err"] += 1


async def run_http_load_test(url, rps, duration):
    """Run load test against a direct HTTP URL using aiohttp."""
    import aiohttp

    stats = {"ok": 0, "err": 0, "latencies": []}
    interval = 1.0 / rps
    end = time.monotonic() + duration

    async with aiohttp.ClientSession() as session:
        tasks = []
        while time.monotonic() < end:
            tasks.append(asyncio.create_task(send_request(session, url, stats)))
            await asyncio.sleep(interval)
        await asyncio.gather(*tasks)

    print_stats(stats, duration)


def print_stats(stats, duration):
    """Print latency and throughput statistics."""
    lats = sorted(stats["latencies"])
    print(f"\n{'=' * 50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if lats:
        p50 = lats[len(lats) // 2]
        p95 = lats[int(len(lats) * 0.95)]
        p99 = lats[int(len(lats) * 0.99)]
        print(f"Latency:   p50={p50:.2f}s  p95={p95:.2f}s  p99={p99:.2f}s")
        print(f"Throughput: {stats['ok'] / duration:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Load test for NVIDIA NIM on SageMaker")
    p.add_argument("url", nargs="?", default=None, help="NIM base URL for direct HTTP mode, e.g. http://localhost:8000")
    p.add_argument("--endpoint-name", help="SageMaker endpoint name (boto3 mode)")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    p.add_argument("--region", default="us-east-1", help="AWS region (default: us-east-1)")
    args = p.parse_args()

    if args.endpoint_name:
        print(f"SageMaker mode: invoking endpoint '{args.endpoint_name}' in {args.region}")
        print(f"Rate: {args.rps} req/s for {args.duration}s")
        run_sagemaker_load_test(args.endpoint_name, args.region, args.rps, args.duration)
    elif args.url:
        print(f"HTTP mode: targeting {args.url}")
        print(f"Rate: {args.rps} req/s for {args.duration}s")
        asyncio.run(run_http_load_test(args.url, args.rps, args.duration))
    else:
        p.error("Provide either --endpoint-name for SageMaker mode or a URL for HTTP mode")
