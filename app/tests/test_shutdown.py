import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest
import uvicorn

from sample_api.config import Settings
from sample_api.main import AppState
from sample_api.server import DrainingServer, build_server

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
NO_PROXY_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def wait_for(predicate, timeout=5.0, interval=0.02):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def make_server(delay: float) -> tuple[DrainingServer, AppState]:
    state = AppState()
    config = uvicorn.Config(app=lambda scope, receive, send: None)
    return DrainingServer(config, state=state, shutdown_delay_seconds=delay), state


def test_first_signal_sets_draining_then_exits_after_delay():
    server, state = make_server(delay=0.5)

    server.handle_exit(signal.SIGTERM, None)

    # Draining starts at once, but the server keeps running during the delay.
    assert state.draining.is_set()
    assert server.should_exit is False
    time.sleep(0.05)
    assert server.should_exit is False

    assert wait_for(lambda: server.should_exit, timeout=2.0)
    assert server.force_exit is False


def test_second_signal_exits_immediately():
    server, state = make_server(delay=30)

    server.handle_exit(signal.SIGTERM, None)
    assert server.should_exit is False

    server.handle_exit(signal.SIGTERM, None)
    assert server.should_exit is True
    assert server.force_exit is True


def test_build_server_uses_settings():
    settings = Settings(app_port=8123, graceful_timeout_seconds=7, shutdown_delay_seconds=2)
    server = build_server(settings)
    assert server.config.port == 8123
    assert server.config.timeout_graceful_shutdown == 7
    assert server.config.access_log is False
    assert server.shutdown_delay_seconds == 2


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http_status(url: str) -> int | None:
    try:
        with NO_PROXY_OPENER.open(url, timeout=1) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except OSError:
        return None


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX signals")
def test_real_process_drains_on_sigterm_then_exits():
    """Start the real server, send SIGTERM, and check the documented shutdown sequence."""
    port = free_port()
    env = {
        **os.environ,
        "PYTHONPATH": str(SRC_DIR),
        "APP_PORT": str(port),
        "SHUTDOWN_DELAY_SECONDS": "2",
        "GRACEFUL_TIMEOUT_SECONDS": "2",
    }
    proc = subprocess.Popen(
        [sys.executable, "-m", "sample_api"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    base = f"http://127.0.0.1:{port}"
    try:
        assert wait_for(lambda: http_status(f"{base}/readyz") == 200, timeout=15), "never ready"

        proc.send_signal(signal.SIGTERM)

        # During the delay: readiness fails, but normal requests are still served.
        assert wait_for(lambda: http_status(f"{base}/readyz") == 503, timeout=1.5)
        assert http_status(f"{base}/") == 200

        output, _ = proc.communicate(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()

    # uvicorn re-raises the signal after a graceful shutdown. Outside a container that ends
    # the process with SIGTERM; as PID 1 in a container the signal is ignored and it exits 0.
    assert proc.returncode in (0, -signal.SIGTERM), output

    messages = [json.loads(line)["msg"] for line in output.splitlines() if line.startswith("{")]
    assert messages[0] == "starting sample-api"
    drain = next(i for i, m in enumerate(messages) if m.startswith("received SIGTERM, draining"))
    done = messages.index("shutdown complete")
    assert drain < done
