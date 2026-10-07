"""Runtime settings (read once from environment variables) and JSON logging setup."""

import json
import logging
import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime

LOG_LEVELS = ("critical", "error", "warning", "info", "debug")


def _get_int(env: Mapping[str, str], key: str, default: int, minimum: int) -> int:
    raw = env.get(key, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{key} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{key} must be >= {minimum}, got {value}")
    return value


def _get_float(env: Mapping[str, str], key: str, default: float, minimum: float) -> float:
    raw = env.get(key, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{key} must be a number, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{key} must be >= {minimum}, got {value}")
    return value


def _get_str(env: Mapping[str, str], key: str, default: str) -> str:
    return env.get(key, "").strip() or default


_TRUE = frozenset({"1", "true", "yes", "on"})
_FALSE = frozenset({"0", "false", "no", "off"})


def _get_bool(env: Mapping[str, str], key: str, default: bool) -> bool:
    raw = env.get(key, "").strip().lower()
    if not raw:
        return default
    if raw in _TRUE:
        return True
    if raw in _FALSE:
        return False
    raise ValueError(f"{key} must be true or false, got {raw!r}")


@dataclass(frozen=True)
class Settings:
    """All runtime settings. Field defaults match the documented env var defaults."""

    app_env: str = "local"
    app_port: int = 8000
    log_level: str = "info"
    shutdown_delay_seconds: float = 3.0
    graceful_timeout_seconds: int = 10
    work_max_ms: int = 2000
    # /work, /error, the API docs and the pod/node names in GET / are for demos only.
    # Production turns them off (chart value app.demoEndpoints=false).
    demo_endpoints: bool = True
    app_version: str = "0.1.0"
    git_commit: str = "unknown"
    pod_name: str = "unknown"
    pod_namespace: str = "unknown"
    node_name: str = "unknown"

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Settings":
        """Build settings from environment variables. Invalid values fail fast at startup."""
        env = os.environ if env is None else env
        log_level = _get_str(env, "LOG_LEVEL", cls.log_level).lower()
        if log_level not in LOG_LEVELS:
            raise ValueError(f"LOG_LEVEL must be one of {', '.join(LOG_LEVELS)}, got {log_level!r}")
        return cls(
            app_env=_get_str(env, "APP_ENV", cls.app_env),
            app_port=_get_int(env, "APP_PORT", cls.app_port, minimum=1),
            log_level=log_level,
            shutdown_delay_seconds=_get_float(
                env, "SHUTDOWN_DELAY_SECONDS", cls.shutdown_delay_seconds, minimum=0.0
            ),
            graceful_timeout_seconds=_get_int(
                env, "GRACEFUL_TIMEOUT_SECONDS", cls.graceful_timeout_seconds, minimum=0
            ),
            work_max_ms=_get_int(env, "WORK_MAX_MS", cls.work_max_ms, minimum=1),
            demo_endpoints=_get_bool(env, "ENABLE_DEMO_ENDPOINTS", cls.demo_endpoints),
            app_version=_get_str(env, "APP_VERSION", cls.app_version),
            git_commit=_get_str(env, "GIT_COMMIT", cls.git_commit),
            pod_name=_get_str(env, "POD_NAME", cls.pod_name),
            pod_namespace=_get_str(env, "POD_NAMESPACE", cls.pod_namespace),
            node_name=_get_str(env, "NODE_NAME", cls.node_name),
        )


class JsonFormatter(logging.Formatter):
    """One JSON object per line: ts, level, logger, msg (+ exc and any ``extra={"ctx": {...}}``)."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        ctx = getattr(record, "ctx", None)
        if isinstance(ctx, Mapping):
            for key, value in ctx.items():
                payload.setdefault(str(key), value)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(level: str = "info") -> None:
    """Send all logs (ours and uvicorn's) to stdout as JSON lines."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
