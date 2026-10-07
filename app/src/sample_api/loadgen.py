"""Small HTTP load generator (standard library only).

The in-cluster demo Jobs (make load, make rollout-test, make alert-demo) run it from the
sample-api image, so no extra image is needed:

    python -m sample_api.loadgen \\
        --url http://traefik.traefik.svc.cluster.local/work?ms=100 \\
        --host app.localtest.me --duration 60 --concurrency 4

Progress goes to stderr every 10 seconds. The last line on stdout is machine-readable:

    RESULT {"total":N,"ok":N,"failed":N,"status_counts":{...},"duration_s":x,"rps":y}

"ok" counts 2xx/3xx responses. "failed" counts everything else: 4xx, 5xx, connection
errors and timeouts (the last two are counted under the "error" key).
"""

import argparse
import json
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from typing import Any, TextIO

PROGRESS_INTERVAL_SECONDS = 10.0
ERROR_KEY = "error"
USER_AGENT = "sample-api-loadgen"

# Ignore any HTTP(S)_PROXY settings in the environment: always talk to the URL directly.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

Sender = Callable[[str, str | None, float], str]


def is_ok(status_key: str) -> bool:
    """2xx and 3xx are successes. Anything else (including "error") is a failure."""
    return status_key.isdigit() and 200 <= int(status_key) < 400


def summarize(status_counts: Mapping[str, int], duration_s: float) -> dict[str, Any]:
    """Build the RESULT summary from per-status counts."""
    total = sum(status_counts.values())
    ok = sum(count for key, count in status_counts.items() if is_ok(key))
    return {
        "total": total,
        "ok": ok,
        "failed": total - ok,
        "status_counts": dict(sorted(status_counts.items())),
        "duration_s": round(duration_s, 2),
        "rps": round(total / duration_s, 2) if duration_s > 0 else 0.0,
    }


class Stats:
    """Thread-safe counter of results keyed by status code string or "error"."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counts: Counter[str] = Counter()

    def record(self, key: str) -> None:
        with self._lock:
            self._counts[key] += 1

    def snapshot(self) -> dict[str, int]:
        with self._lock:
            return dict(self._counts)


def send_request(url: str, host: str | None, timeout: float) -> str:
    """Send one GET request. Returns the status code as a string, or "error"."""
    headers = {"User-Agent": USER_AGENT}
    if host:
        headers["Host"] = host
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            response.read()
            return str(response.status)
    except urllib.error.HTTPError as exc:  # 4xx/5xx still carry a status code
        exc.close()
        return str(exc.code)
    except Exception:  # connection refused/reset, timeout, bad response, ...
        return ERROR_KEY


def _worker(
    send: Sender,
    url: str,
    host: str | None,
    timeout: float,
    rate: float,
    deadline: float,
    stop: threading.Event,
    stats: Stats,
) -> None:
    interval = 1.0 / rate if rate > 0 else 0.0
    next_at = time.monotonic()
    while not stop.is_set():
        now = time.monotonic()
        if now >= deadline:
            return
        if interval and next_at > now:
            stop.wait(min(next_at - now, deadline - now))
            continue
        stats.record(send(url, host, timeout))
        if interval:
            # Keep the pace, but never "catch up" with a burst after a slow response.
            next_at = max(next_at + interval, time.monotonic())


def run(
    url: str,
    *,
    host: str | None = None,
    duration: float = 60.0,
    concurrency: int = 4,
    rate: float = 0.0,
    timeout: float = 5.0,
    progress: TextIO | None = None,
    send: Sender = send_request,
) -> dict[str, Any]:
    """Run the load and return the summary dict (see ``summarize``)."""
    stats = Stats()
    stop = threading.Event()
    start = time.monotonic()
    deadline = start + duration
    threads = [
        threading.Thread(
            target=_worker,
            args=(send, url, host, timeout, rate, deadline, stop, stats),
            name=f"loadgen-{i}",
            daemon=True,
        )
        for i in range(concurrency)
    ]
    for thread in threads:
        thread.start()

    next_progress = start + PROGRESS_INTERVAL_SECONDS
    try:
        while alive := [thread for thread in threads if thread.is_alive()]:
            alive[0].join(timeout=0.2)
            now = time.monotonic()
            if progress is not None and now >= next_progress:
                summary = summarize(stats.snapshot(), now - start)
                print(
                    f"t={now - start:.0f}s total={summary['total']} failed={summary['failed']}",
                    file=progress,
                    flush=True,
                )
                next_progress += PROGRESS_INTERVAL_SECONDS
    except KeyboardInterrupt:
        stop.set()
        for thread in threads:
            thread.join(timeout=timeout + 1)

    return summarize(stats.snapshot(), time.monotonic() - start)


def _positive_float(value: str) -> float:
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError(f"must be > 0, got {value}")
    return number


def _non_negative_float(value: str) -> float:
    number = float(value)
    if number < 0:
        raise argparse.ArgumentTypeError(f"must be >= 0, got {value}")
    return number


def _positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError(f"must be >= 1, got {value}")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m sample_api.loadgen",
        description="Send HTTP GET load to a URL and print a RESULT summary line.",
    )
    parser.add_argument("--url", required=True, help="target URL, e.g. http://host/work?ms=100")
    parser.add_argument("--host", help="optional Host header, e.g. app.localtest.me")
    parser.add_argument(
        "--duration", type=_positive_float, default=60.0, help="seconds (default 60)"
    )
    parser.add_argument(
        "--concurrency", type=_positive_int, default=4, help="worker threads (default 4)"
    )
    parser.add_argument(
        "--rate",
        type=_non_negative_float,
        default=0.0,
        help="requests/sec per worker; 0 = as fast as possible (default 0)",
    )
    parser.add_argument(
        "--timeout", type=_positive_float, default=5.0, help="per-request timeout (default 5)"
    )
    parser.add_argument("--fail-on-error", action="store_true", help="exit 1 if any request failed")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    print(
        f"loadgen: url={args.url} host={args.host or '-'} duration={args.duration:g}s "
        f"concurrency={args.concurrency} rate={args.rate:g}/s per worker",
        file=sys.stderr,
        flush=True,
    )
    summary = run(
        args.url,
        host=args.host,
        duration=args.duration,
        concurrency=args.concurrency,
        rate=args.rate,
        timeout=args.timeout,
        progress=sys.stderr,
    )
    print("RESULT " + json.dumps(summary, separators=(",", ":")), flush=True)
    if args.fail_on_error and summary["failed"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
