import pytest
from fastapi.testclient import TestClient
from prometheus_client import CollectorRegistry

from sample_api.main import AppState, create_app


def requests_total(registry, method, path, status):
    value = registry.get_sample_value(
        "http_requests_total", {"method": method, "path": path, "status": status}
    )
    return value or 0.0


def test_metrics_endpoint_exposes_request_counter(client):
    client.get("/")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert 'http_requests_total{method="GET",path="/",status="200"} 1.0' in response.text


def test_requests_are_counted_by_route_template_and_status(client, registry):
    client.get("/work", params={"ms": 5})
    client.get("/work", params={"ms": 5})
    client.get("/error", params={"rate": 1})
    client.get("/error", params={"rate": 0})

    assert requests_total(registry, "GET", "/work", "200") == 2
    assert requests_total(registry, "GET", "/error", "500") == 1
    assert requests_total(registry, "GET", "/error", "200") == 1


def test_validation_errors_are_counted_as_4xx(client, registry):
    client.get("/work", params={"ms": 0})
    assert requests_total(registry, "GET", "/work", "422") == 1


def test_latency_histogram_is_recorded(client, registry):
    client.get("/work", params={"ms": 30})
    count = registry.get_sample_value(
        "http_request_duration_seconds_count", {"method": "GET", "path": "/work"}
    )
    total = registry.get_sample_value(
        "http_request_duration_seconds_sum", {"method": "GET", "path": "/work"}
    )
    assert count == 1
    assert total >= 0.03
    # 0.5 must be a bucket edge: the latency alert threshold is 500ms.
    le_half = registry.get_sample_value(
        "http_request_duration_seconds_bucket", {"method": "GET", "path": "/work", "le": "0.5"}
    )
    assert le_half == 1


@pytest.mark.parametrize("path", ["/healthz", "/readyz", "/metrics"])
def test_probe_and_scrape_paths_are_not_counted(client, registry, path):
    client.get(path)
    client.get(path)
    for status in ("200", "503"):
        assert requests_total(registry, "GET", path, status) == 0
    assert registry.get_sample_value("http_requests_in_progress") == 0


def test_unknown_path_is_labelled_unmatched(client, registry):
    response = client.get("/does-not-exist/12345")
    assert response.status_code == 404
    assert requests_total(registry, "GET", "unmatched", "404") == 1
    assert requests_total(registry, "GET", "/does-not-exist/12345", "404") == 0


def test_unusual_http_method_is_bucketed(client, registry):
    client.request("PROPFIND", "/")
    assert requests_total(registry, "OTHER", "/", "405") == 1


def test_unhandled_exception_is_recorded_as_500(settings):
    registry = CollectorRegistry()
    app = create_app(settings, registry=registry, state=AppState())

    @app.get("/boom")
    async def boom():
        raise RuntimeError("boom")

    with TestClient(app, raise_server_exceptions=False) as client:
        assert client.get("/boom").status_code == 500
    assert requests_total(registry, "GET", "/boom", "500") == 1


def test_build_info_carries_version_and_commit(client, registry):
    value = registry.get_sample_value(
        "sample_api_build_info", {"version": "9.9.9-test", "commit": "abc1234"}
    )
    assert value == 1


def test_no_created_series_are_exported(client):
    client.get("/")
    assert "http_requests_created" not in client.get("/metrics").text
