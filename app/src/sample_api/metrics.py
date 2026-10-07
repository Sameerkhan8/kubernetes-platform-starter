"""Prometheus metrics for sample-api and the ASGI middleware that records them.

Metric names and labels are an interface: the alert rules and the Grafana dashboard in
charts/sample-api depend on them. Change them together.
"""

import time

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram
from starlette.types import ASGIApp, Message, Receive, Scope, Send

# Probe and scrape endpoints are not counted, so they do not dilute error ratios or latency.
EXCLUDED_PATHS = frozenset({"/metrics", "/healthz", "/readyz"})

# 0.5 is a bucket edge because the latency alert threshold is 500ms.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)

# Any other method is recorded as "OTHER", so odd clients cannot create new label values.
KNOWN_METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})

UNMATCHED_PATH = "unmatched"


class Metrics:
    """The application's metric objects, registered in one registry."""

    def __init__(self, registry: CollectorRegistry, *, version: str, commit: str) -> None:
        self.requests = Counter(
            "http_requests_total",
            "HTTP requests by method, route template and status code.",
            ["method", "path", "status"],
            registry=registry,
        )
        self.latency = Histogram(
            "http_request_duration_seconds",
            "HTTP request duration in seconds, by method and route template.",
            ["method", "path"],
            buckets=LATENCY_BUCKETS,
            registry=registry,
        )
        self.in_progress = Gauge(
            "http_requests_in_progress",
            "HTTP requests currently being served.",
            registry=registry,
        )
        self.build_info = Gauge(
            "sample_api_build_info",
            "Always 1. The labels carry the running version and git commit.",
            ["version", "commit"],
            registry=registry,
        )
        self.build_info.labels(version=version, commit=commit).set(1)


def route_template(scope: Scope) -> str:
    """Return the matched route template (e.g. "/work"), or "unmatched" (keeps labels bounded)."""
    route = scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) and path else UNMATCHED_PATH


class PrometheusMiddleware:
    """Pure ASGI middleware: counts requests and observes latency per route template."""

    def __init__(self, app: ASGIApp, metrics: Metrics) -> None:
        self.app = app
        self.metrics = metrics

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in EXCLUDED_PATHS:
            await self.app(scope, receive, send)
            return

        method = scope["method"] if scope["method"] in KNOWN_METHODS else "OTHER"
        status_code = 500

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
            await send(message)

        self.metrics.in_progress.inc()
        start = time.perf_counter()
        try:
            await self.app(scope, receive, send_wrapper)
        except Exception:
            # Unhandled exceptions become a 500 response further up the stack.
            status_code = 500
            raise
        finally:
            elapsed = time.perf_counter() - start
            path = route_template(scope)
            self.metrics.in_progress.dec()
            self.metrics.requests.labels(method=method, path=path, status=str(status_code)).inc()
            self.metrics.latency.labels(method=method, path=path).observe(elapsed)
