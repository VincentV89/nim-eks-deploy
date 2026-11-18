"""
Load test for NIM on SageMaker — fires concurrent chat completions to trigger
GPU-based endpoint autoscaling.

Usage:
  # SageMaker endpoint (SigV4-signed via boto3)
  python load_test.py --endpoint-name nim-demo-nim-llm --rps 20 --duration 60
  # Any OpenAI-compatible NIM URL (e.g. local `docker run`)
  python load_test.py --url http://localhost:8000 --rps 20 --duration 60
"""
import argparse, asyncio, json, time

PAYLOAD = {
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
}


def make_sagemaker_sender(endpoint_name, region, concurrency):
    import boto3
    from botocore.config import Config

    client = boto3.client(
        "sagemaker-runtime",
        region_name=region,
        config=Config(max_pool_connections=concurrency, retries={"max_attempts": 0}),
    )
    body = json.dumps(PAYLOAD)

    def invoke():
        resp = client.invoke_endpoint(
            EndpointName=endpoint_name, ContentType="application/json", Body=body
        )
        resp["Body"].read()

    async def send():
        await asyncio.to_thread(invoke)

    return send, None


def make_http_sender(url):
    import aiohttp

    session = aiohttp.ClientSession()

    async def send():
        async with session.post(f"{url}/v1/chat/completions", json=PAYLOAD) as r:
            r.raise_for_status()
            await r.read()

    return send, session


async def timed(send, stats):
    t0 = time.monotonic()
    try:
        await send()
        stats["ok"] += 1
        stats["latencies"].append(time.monotonic() - t0)
    except Exception:
        stats["err"] += 1


async def main(args):
    stats = {"ok": 0, "err": 0, "latencies": []}
    interval = 1.0 / args.rps

    if args.endpoint_name:
        send, session = make_sagemaker_sender(args.endpoint_name, args.region, args.rps * 10)
    else:
        send, session = make_http_sender(args.url.rstrip("/"))

    try:
        tasks = []
        end = time.monotonic() + args.duration
        while time.monotonic() < end:
            tasks.append(asyncio.create_task(timed(send, stats)))
            await asyncio.sleep(interval)
        await asyncio.gather(*tasks)
    finally:
        if session is not None:
            await session.close()

    lats = sorted(stats["latencies"])
    print(f"\n{'='*50}")
    print(f"Requests:  {stats['ok']} ok / {stats['err']} errors")
    if lats:
        print(f"Latency:   p50={lats[len(lats)//2]:.2f}s  p95={lats[int(len(lats)*0.95)]:.2f}s  p99={lats[int(len(lats)*0.99)]:.2f}s")
        print(f"Throughput: {stats['ok']/args.duration:.1f} req/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--endpoint-name", help="SageMaker endpoint name, e.g. nim-demo-nim-llm")
    target.add_argument("--url", help="OpenAI-compatible NIM base URL, e.g. http://localhost:8000")
    p.add_argument("--region", default=None, help="AWS region (defaults to your AWS config)")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    asyncio.run(main(p.parse_args()))
