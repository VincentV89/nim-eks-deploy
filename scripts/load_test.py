"""
Load test for NIM on SageMaker -- fires concurrent chat completions to trigger auto scaling.
Usage: python load_test.py <endpoint-name> --rps 20 --duration 60
"""
import argparse, asyncio, time, json, threading
from concurrent.futures import ThreadPoolExecutor

import boto3

PAYLOAD = json.dumps({
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
})


def invoke_endpoint(client, endpoint_name):
    """Invoke the SageMaker endpoint synchronously (called from executor)."""
    response = client.invoke_endpoint(
        EndpointName=endpoint_name,
        ContentType="application/json",
        Body=PAYLOAD,
    )
    response["Body"].read()


async def send_request(loop, executor, client, endpoint_name, stats, lock):
    t0 = time.monotonic()
    try:
        await loop.run_in_executor(executor, invoke_endpoint, client, endpoint_name)
        latency = time.monotonic() - t0
        with lock:
            stats["ok"] += 1
            stats["latencies"].append(latency)
    except Exception:
        with lock:
            stats["err"] += 1


async def main(endpoint_name, rps, duration):
    stats = {"ok": 0, "err": 0, "latencies": []}
    lock = threading.Lock()
    interval = 1.0 / rps
    end = time.monotonic() + duration

    client = boto3.client("sagemaker-runtime")
    loop = asyncio.get_event_loop()
    executor = ThreadPoolExecutor(max_workers=rps * 2)

    tasks = []
    while time.monotonic() < end:
        tasks.append(asyncio.ensure_future(
            send_request(loop, executor, client, endpoint_name, stats, lock)
        ))
        await asyncio.sleep(interval)
    await asyncio.gather(*tasks)

    executor.shutdown(wait=False)

    lats = sorted(stats["latencies"])
    print(f"\n{'='*50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/duration:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("endpoint_name", help="SageMaker endpoint name")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    args = p.parse_args()
    asyncio.run(main(args.endpoint_name, args.rps, args.duration))
