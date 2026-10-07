"""FastAPI application factory and HTTP routes."""

import logging
import random
import threading
import time
from typing import Annotated, Any

from fastapi import FastAPI, Query, Response
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    disable_created_metrics,
    generate_latest,
)

from sample_api.config import Settings
from sample_api.metrics import Metrics, PrometheusMiddleware

logger = logging.getLogger("sample_api")


class AppState:
    """State shared by the HTTP routes and the server's signal handler."""

    def __init__(self) -> None:
        # Set on the first SIGTERM/SIGINT. /readyz then returns 503 so Kubernetes and the
        # gateway stop sending new traffic while in-flight requests finish.
        self.draining = threading.Event()


def burn_cpu(ms: int) -> None:
    """Keep one CPU core busy for ``ms`` milliseconds (wall clock)."""
    deadline = time.perf_counter() + ms / 1000
    while time.perf_counter() < deadline:
        pass


def create_app(
    settings: Settings | None = None,
    *,
    registry: CollectorRegistry | None = None,
    state: AppState | None = None,
) -> FastAPI:
    """Build the app. Tests pass a fresh registry and state; production uses the defaults."""
    settings = settings or Settings.from_env()
    # The default registry also exports process_* and python_* metrics.
    registry = REGISTRY if registry is None else registry
    state = AppState() if state is None else state

    # Skip the extra *_created series; nothing here uses them.
    disable_created_metrics()
    metrics = Metrics(registry, version=settings.app_version, commit=settings.git_commit)

    demo = settings.demo_endpoints
    app = FastAPI(
        title="sample-api",
        version=settings.app_version,
        description="Demo service for kubernetes-platform-starter.",
        # The interactive API docs are a demo convenience; production does not publish them.
        docs_url="/docs" if demo else None,
        redoc_url="/redoc" if demo else None,
        openapi_url="/openapi.json" if demo else None,
    )
    app.state.sample_api = state
    app.add_middleware(PrometheusMiddleware, metrics=metrics)

    @app.get("/", summary="Service info")
    async def root() -> dict[str, str]:
        info = {
            "service": "sample-api",
            "version": settings.app_version,
            "environment": settings.app_env,
        }
        if demo:
            # Shows which pod and node answered (useful in the load and rollout demos).
            # Left out in production: it would tell anyone the internal names.
            info["pod"] = settings.pod_name
            info["node"] = settings.node_name
        info["message"] = "Hello from sample-api"
        return info

    @app.get("/healthz", summary="Liveness: the process is alive")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz", summary="Readiness: 503 while draining after SIGTERM")
    async def readyz() -> Any:
        if state.draining.is_set():
            return JSONResponse({"status": "draining"}, status_code=503)
        return {"status": "ready"}

    @app.get("/metrics", summary="Prometheus metrics", include_in_schema=False)
    def metrics_endpoint() -> Response:
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    if demo:
        _add_demo_routes(app, settings)

    return app


def _add_demo_routes(app: FastAPI, settings: Settings) -> None:
    """/work (CPU burn for the HPA demo) and /error (5xx injection for the alert demo).

    Never expose these on a public route: /work lets anyone burn CPU and scale the
    Deployment up, and /error returns failures on demand.
    """

    # A plain "def" route runs in the threadpool, so the CPU burn does not block the event loop.
    @app.get("/work", summary="Burn CPU for N milliseconds (HPA demo)")
    def work(
        ms: Annotated[
            int, Query(ge=1, le=settings.work_max_ms, description="Milliseconds of CPU to burn")
        ] = 100,
    ) -> dict[str, int]:
        burn_cpu(ms)
        return {"burned_ms": ms}

    @app.get("/error", summary="Return 500 with probability `rate` (alert demo)")
    async def error(
        rate: Annotated[
            float, Query(ge=0.0, le=1.0, description="Probability of a 500 response")
        ] = 1.0,
    ) -> Any:
        if random.random() < rate:
            return JSONResponse({"error": "injected failure"}, status_code=500)
        return {"status": "ok"}
