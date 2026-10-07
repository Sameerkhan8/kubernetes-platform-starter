from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from prometheus_client import CollectorRegistry

from sample_api.config import Settings
from sample_api.main import AppState, create_app


@pytest.fixture
def settings() -> Settings:
    return Settings(
        app_env="test",
        app_version="9.9.9-test",
        git_commit="abc1234",
        pod_name="sample-api-test-pod",
        node_name="test-node",
        work_max_ms=500,
    )


@pytest.fixture
def registry() -> CollectorRegistry:
    # A fresh registry per test, so metric values never leak between tests.
    return CollectorRegistry()


@pytest.fixture
def state() -> AppState:
    return AppState()


@pytest.fixture
def client(
    settings: Settings, registry: CollectorRegistry, state: AppState
) -> Iterator[TestClient]:
    app = create_app(settings, registry=registry, state=state)
    with TestClient(app) as test_client:
        yield test_client
