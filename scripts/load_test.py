"""
Load test for NIM on SageMaker — fires concurrent chat completions to trigger GPU autoscaling.

Usage:
  # SageMaker endpoint (requests are SigV4-signed with your AWS credentials)
  python load_test.py --sagemaker-endpoint nim-demo --region us-east-1 --rps 20 --duration 60

  # Any OpenAI-compatible NIM URL (e.g. a local container on :8000)
  python load_test.py http://localhost:8000 --rps 20 --duration 60
"""
import argparse, asyncio, json, time, aiohttp

PAYLOAD = {
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Explain KV cache in transformer inference in 2 sentences."}],
    "max_tokens": 100,
}
BODY = json.dumps(PAYLOAD)


class SageMakerSigner:
    """Builds SigV4-signed headers for SageMaker Runtime InvokeEndpoint."""

    def __init__(self, endpoint, region):
        import boto3
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest

        session = boto3.Session(region_name=region)
        self.region = region or session.region_name
        if not self.region:
            raise SystemExit("AWS region is required (--region or AWS_REGION)")
        self.url = f"https://runtime.sagemaker.{self.region}.amazonaws.com/endpoints/{endpoint}/invocations"
        self._creds = session.get_credentials()
        if self._creds is None:
            raise SystemExit("No AWS credentials found")
        self._auth, self._request = SigV4Auth, AWSRequest

    def headers(self):
        req = self._request(method="POST", url=self.url, data=BODY,
                            headers={"Content-Type": "application/json"})
        self._auth(self._creds.get_frozen_credentials(), "sagemaker", self.region).add_auth(req)
        return dict(req.headers)


async def send_request(session, url, headers_fn, stats):
    t0 = time.monotonic()
    try:
        async with session.post(url, data=BODY, headers=headers_fn()) as r:
            await r.read()
            if r.status != 200:
                stats["err"] += 1
                return
            stats["ok"] += 1
            stats["latencies"].append(time.monotonic() - t0)
    except Exception:
        stats["err"] += 1


async def main(url, headers_fn, rps, duration):
    stats = {"ok": 0, "err": 0, "latencies": []}
    interval = 1.0 / rps
    end = time.monotonic() + duration

    async with aiohttp.ClientSession() as session:
        tasks = []
        while time.monotonic() < end:
            tasks.append(asyncio.create_task(send_request(session, url, headers_fn, stats)))
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
    p.add_argument("url", nargs="?", help="OpenAI-compatible NIM base URL, e.g. http://localhost:8000")
    p.add_argument("--sagemaker-endpoint", help="SageMaker endpoint name (e.g. nim-demo)")
    p.add_argument("--region", help="AWS region of the SageMaker endpoint")
    p.add_argument("--rps", type=int, default=10, help="Requests per second")
    p.add_argument("--duration", type=int, default=60, help="Test duration in seconds")
    args = p.parse_args()

    if bool(args.url) == bool(args.sagemaker_endpoint):
        p.error("provide exactly one of: url, --sagemaker-endpoint")

    if args.sagemaker_endpoint:
        signer = SageMakerSigner(args.sagemaker_endpoint, args.region)
        target, headers_fn = signer.url, signer.headers
    else:
        target = f"{args.url.rstrip('/')}/v1/chat/completions"
        headers_fn = lambda: {"Content-Type": "application/json"}

    asyncio.run(main(target, headers_fn, args.rps, args.duration))
