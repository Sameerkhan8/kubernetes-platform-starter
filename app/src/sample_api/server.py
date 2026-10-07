"""uvicorn server with a graceful drain on SIGTERM.

Shutdown sequence inside a Kubernetes pod (see docs/decisions/0002):

1. The kubelet runs the preStop hook (sleep). Meanwhile the endpoint is removed from the
   Service and the gateway stops sending new requests to this pod.
2. SIGTERM arrives. ``handle_exit`` sets the draining flag, so /readyz returns 503, and the
   pod keeps serving for SHUTDOWN_DELAY_SECONDS as a second safety margin.
3. uvicorn stops accepting connections and waits up to GRACEFUL_TIMEOUT_SECONDS for
   in-flight requests to finish, then the process exits.

A second SIGTERM/SIGINT skips the remaining delay and exits at once.
"""

import logging
import signal
import threading
from types import FrameType

import uvicorn

from sample_api.config import Settings, configure_logging
from sample_api.main import AppState, create_app

logger = logging.getLogger("sample_api.server")


class DrainingServer(uvicorn.Server):
    """uvicorn.Server that delays shutdown on the first signal (checked against uvicorn 0.54)."""

    def __init__(
        self, config: uvicorn.Config, *, state: AppState, shutdown_delay_seconds: float
    ) -> None:
        super().__init__(config)
        self.state = state
        self.shutdown_delay_seconds = shutdown_delay_seconds
        self._drain_timer: threading.Timer | None = None

    def handle_exit(self, sig: int, frame: FrameType | None) -> None:
        if self.state.draining.is_set():
            # Second signal: stop waiting and exit now.
            logger.warning("second signal %s received, exiting now", signal.Signals(sig).name)
            if self._drain_timer is not None:
                self._drain_timer.cancel()
            self.force_exit = True
            super().handle_exit(sig, frame)
            return

        self.state.draining.set()
        logger.info(
            "received %s, draining: /readyz now returns 503; shutdown starts in %ss",
            signal.Signals(sig).name,
            self.shutdown_delay_seconds,
        )
        self._drain_timer = threading.Timer(
            self.shutdown_delay_seconds, super().handle_exit, args=(sig, frame)
        )
        self._drain_timer.daemon = True
        self._drain_timer.start()

    async def shutdown(self, sockets: list | None = None) -> None:
        await super().shutdown(sockets=sockets)
        logger.info("shutdown complete")


def build_server(settings: Settings, state: AppState | None = None) -> DrainingServer:
    state = AppState() if state is None else state
    app = create_app(settings, state=state)
    config = uvicorn.Config(
        app,
        host="0.0.0.0",  # all interfaces inside the container
        port=settings.app_port,
        workers=1,  # scale with pods, not workers
        log_config=None,  # keep our JSON logging
        log_level=settings.log_level,
        access_log=False,  # request metrics cover this; keeps logs small
        server_header=False,
        timeout_graceful_shutdown=settings.graceful_timeout_seconds,
    )
    return DrainingServer(
        config, state=state, shutdown_delay_seconds=settings.shutdown_delay_seconds
    )


def run() -> None:
    settings = Settings.from_env()
    configure_logging(settings.log_level)
    logger.info(
        "starting sample-api",
        extra={
            "ctx": {
                "version": settings.app_version,
                "commit": settings.git_commit,
                "environment": settings.app_env,
                "port": settings.app_port,
                "pod": settings.pod_name,
                "node": settings.node_name,
            }
        },
    )
    build_server(settings).run()
