import contextlib
import json
import socket
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from sample_api import loadgen


def test_summarize_counts_ok_and_failed():
    summary = loadgen.summarize({"200": 6, "302": 1, "404": 1, "500": 1, "error": 1}, 2.0)
    assert summary == {
        "total": 10,
        "ok": 7,
        "failed": 3,
        "status_counts": {"200": 6, "302": 1, "404": 1, "500": 1, "error": 1},
        "duration_s": 2.0,
        "rps": 5.0,
    }


def test_summarize_handles_no_requests():
    summary = loadgen.summarize({}, 0.0)
    assert summary["total"] == 0
    assert summary["failed"] == 0
    assert summary["rps"] == 0.0


@pytest.mark.parametrize(
    ("key", "expected"),
    [
        ("200", True),
        ("204", True),
        ("301", True),
        ("399", True),
        ("404", False),
        ("500", False),
        ("error", False),
        ("199", False),
    ],
)
def test_is_ok(key, expected):
    assert loadgen.is_ok(key) is expected


def test_run_with_fake_sender_respects_rate_and_concurrency():
    calls = []

    def fake_send(url, host, timeout):
        calls.append((url, host))
        return "200"

    summary = loadgen.run(
        "http://example.invalid/", host="h", duration=0.5, concurrency=2, rate=10, send=fake_send
    )
    # 2 workers x 10 req/s x 0.5 s = about 10 requests (first request is sent at t=0).
    assert 8 <= summary["total"] <= 14
    assert summary["failed"] == 0
    assert calls[0] == ("http://example.invalid/", "h")


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status = 500 if self.path.startswith("/fail") else 200
        body = json.dumps({"host": self.headers.get("Host")}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.seen_hosts.add(self.headers.get("Host"))

    def log_message(self, format, *args):  # keep test output quiet
        pass


@pytest.fixture
def http_server() -> Iterator[ThreadingHTTPServer]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    server.seen_hosts = set()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def test_real_run_against_local_server(http_server):
    port = http_server.server_address[1]
    summary = loadgen.run(
        f"http://127.0.0.1:{port}/ok", host="app.localtest.me", duration=0.5, concurrency=2
    )
    assert summary["total"] > 0
    assert summary["failed"] == 0
    assert summary["status_counts"] == {"200": summary["total"]}
    assert http_server.seen_hosts == {"app.localtest.me"}


def test_http_errors_and_connection_errors_count_as_failed(http_server):
    port = http_server.server_address[1]
    assert loadgen.send_request(f"http://127.0.0.1:{port}/fail", None, 2) == "500"

    with unused_port() as closed_port:
        assert loadgen.send_request(f"http://127.0.0.1:{closed_port}/", None, 2) == "error"


def test_main_prints_result_line_and_fails_on_error(http_server, capsys):
    port = http_server.server_address[1]
    exit_code = loadgen.main(
        [
            "--url",
            f"http://127.0.0.1:{port}/fail",
            "--duration",
            "0.3",
            "--concurrency",
            "1",
            "--rate",
            "20",
            "--fail-on-error",
        ]
    )
    out = capsys.readouterr().out.strip().splitlines()
    assert exit_code == 1
    assert out[-1].startswith("RESULT ")
    result = json.loads(out[-1].removeprefix("RESULT "))
    assert set(result) == {"total", "ok", "failed", "status_counts", "duration_s", "rps"}
    assert result["failed"] == result["total"] > 0
    assert set(result["status_counts"]) == {"500"}


def test_main_exits_zero_without_fail_on_error(http_server, capsys):
    port = http_server.server_address[1]
    exit_code = loadgen.main(
        ["--url", f"http://127.0.0.1:{port}/fail", "--duration", "0.2", "--rate", "10"]
    )
    assert exit_code == 0
    assert capsys.readouterr().out.startswith("RESULT ")


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["--url", "http://x/", "--duration", "0"],
        ["--url", "http://x/", "--concurrency", "0"],
        ["--url", "http://x/", "--rate", "-1"],
    ],
)
def test_main_rejects_bad_arguments(argv):
    with pytest.raises(SystemExit):
        loadgen.main(argv)


@contextlib.contextmanager
def unused_port() -> Iterator[int]:
    """Yield a port number that is bound but not listening, so connections are refused."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        yield sock.getsockname()[1]
