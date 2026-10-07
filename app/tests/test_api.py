import pytest
from fastapi.testclient import TestClient

from sample_api.config import Settings
from sample_api.main import create_app


def test_root_returns_service_info(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {
        "service": "sample-api",
        "version": "9.9.9-test",
        "environment": "test",
        "pod": "sample-api-test-pod",
        "node": "test-node",
        "message": "Hello from sample-api",
    }


def test_healthz_is_ok(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_flips_to_503_when_draining(client, state):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}

    state.draining.set()

    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.json() == {"status": "draining"}
    # Liveness stays green while draining: the process is healthy, just leaving.
    assert client.get("/healthz").status_code == 200


def test_work_burns_cpu_for_requested_ms(client):
    response = client.get("/work", params={"ms": 20})
    assert response.status_code == 200
    assert response.json() == {"burned_ms": 20}


def test_work_default_is_100ms(client):
    assert client.get("/work").json() == {"burned_ms": 100}


@pytest.mark.parametrize("ms", [0, -5, 501, "abc"])
def test_work_rejects_out_of_range_values(client, ms):
    # work_max_ms is 500 in the test settings.
    assert client.get("/work", params={"ms": ms}).status_code == 422


def test_error_rate_one_always_fails(client):
    for _ in range(5):
        response = client.get("/error", params={"rate": 1})
        assert response.status_code == 500
        assert response.json() == {"error": "injected failure"}


def test_error_default_rate_is_one(client):
    assert client.get("/error").status_code == 500


def test_error_rate_zero_never_fails(client):
    for _ in range(5):
        response = client.get("/error", params={"rate": 0})
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}


@pytest.mark.parametrize("rate", [-0.1, 1.5, "abc"])
def test_error_rejects_out_of_range_rate(client, rate):
    assert client.get("/error", params={"rate": rate}).status_code == 422


def test_settings_defaults_match_documentation():
    settings = Settings.from_env({})
    assert settings.app_env == "local"
    assert settings.app_port == 8000
    assert settings.log_level == "info"
    assert settings.shutdown_delay_seconds == 3.0
    assert settings.graceful_timeout_seconds == 10
    assert settings.work_max_ms == 2000
    assert settings.app_version == "0.1.0"
    assert settings.git_commit == "unknown"
    assert settings.pod_name == "unknown"
    assert settings.pod_namespace == "unknown"
    assert settings.node_name == "unknown"
    assert settings.demo_endpoints is True


def test_settings_read_from_env():
    settings = Settings.from_env(
        {
            "APP_ENV": "dev",
            "APP_PORT": "9000",
            "LOG_LEVEL": "DEBUG",
            "SHUTDOWN_DELAY_SECONDS": "1.5",
            "GRACEFUL_TIMEOUT_SECONDS": "20",
            "WORK_MAX_MS": "750",
            "POD_NAME": "pod-1",
            "ENABLE_DEMO_ENDPOINTS": "false",
        }
    )
    assert settings.app_env == "dev"
    assert settings.app_port == 9000
    assert settings.log_level == "debug"
    assert settings.shutdown_delay_seconds == 1.5
    assert settings.graceful_timeout_seconds == 20
    assert settings.work_max_ms == 750
    assert settings.pod_name == "pod-1"
    assert settings.demo_endpoints is False


@pytest.mark.parametrize(
    "env",
    [
        {"APP_PORT": "eighty"},
        {"APP_PORT": "0"},
        {"WORK_MAX_MS": "0"},
        {"SHUTDOWN_DELAY_SECONDS": "-1"},
        {"LOG_LEVEL": "loud"},
        {"ENABLE_DEMO_ENDPOINTS": "maybe"},
    ],
)
def test_settings_reject_invalid_values(env):
    with pytest.raises(ValueError):
        Settings.from_env(env)


def test_api_docs_are_served_in_demo_mode(client):
    assert client.get("/docs").status_code == 200
    assert client.get("/openapi.json").status_code == 200


# ---------------------------------------------------------------- production mode
# values-prod.yaml sets app.demoEndpoints=false (env ENABLE_DEMO_ENDPOINTS=false).


@pytest.fixture
def prod_client(registry, state):
    settings = Settings(
        app_env="prod", pod_name="secret-pod", node_name="secret-node", demo_endpoints=False
    )
    with TestClient(create_app(settings, registry=registry, state=state)) as test_client:
        yield test_client


@pytest.mark.parametrize("path", ["/work", "/error", "/docs", "/redoc", "/openapi.json"])
def test_demo_endpoints_and_docs_are_gone_in_production_mode(prod_client, path):
    assert prod_client.get(path).status_code == 404


def test_root_hides_pod_and_node_in_production_mode(prod_client):
    body = prod_client.get("/").json()
    assert body == {
        "service": "sample-api",
        "version": "0.1.0",
        "environment": "prod",
        "message": "Hello from sample-api",
    }


@pytest.mark.parametrize("path", ["/healthz", "/readyz", "/metrics"])
def test_probes_and_metrics_still_work_in_production_mode(prod_client, path):
    assert prod_client.get(path).status_code == 200
