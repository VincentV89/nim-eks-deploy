"""
Load test for NIM on a SageMaker endpoint — fires concurrent chat completions
(via InvokeEndpoint) to trigger GPU-utilization autoscaling.
Usage: python load_test.py <ENDPOINT_NAME> --region us-east-1 --rps 20 --duration 60
"""
import argparse, asyncio, json, time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

PAYLOAD = json.dumps({
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
})

MAX_CONCURRENCY = 256


def invoke(client, endpoint):
    r = client.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=PAYLOAD)
    r["Body"].read()


async def send_request(loop, client, endpoint, stats):
    t0 = time.monotonic()
    try:
        await loop.run_in_executor(None, invoke, client, endpoint)
        stats["ok"] += 1
        stats["latencies"].append(time.monotonic() - t0)
    except Exception:
        stats["err"] += 1


async def main(endpoint, region, rps, duration):
    loop = asyncio.get_running_loop()
    loop.set_default_executor(ThreadPoolExecutor(max_workers=MAX_CONCURRENCY))
    client = boto3.client(
        "sagemaker-runtime",
        region_name=region,
        config=Config(max_pool_connections=MAX_CONCURRENCY, retries={"max_attempts": 0}, read_timeout=120),
    )

    stats = {"ok": 0, "err": 0, "latencies": []}
    interval = 1.0 / rps
    end = time.monotonic() + duration

    tasks = []
    while time.monotonic() < end:
        tasks.append(asyncio.create_task(send_request(loop, client, endpoint, stats)))
        await asyncio.sleep(interval)
    await asyncio.gather(*tasks)

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
    asyncio.run(main(args.endpoint, args.region, args.rps, args.duration))
