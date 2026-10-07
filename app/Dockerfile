# sample-api container image. Multi-stage build:
#   base     - pinned Python base image + Python env settings
#   builder  - virtualenv with the pinned runtime dependencies
#   test     - builder + dev tools; runs ruff and pytest (docker build --target test app/)
#   runtime  - default (last) stage: venv + app code, non-root uid 10001
#
# Build:  docker build -t sample-api:dev --build-arg APP_VERSION=0.1.0 --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) app/
# Test:   docker build --target test app/

# Base image pinned by digest (multi-arch index). It is written out in the FROM line on
# purpose: Dependabot (.github/dependabot.yml) only updates literal FROM lines, not ARGs.
FROM python:3.14.8-slim-trixie@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2 AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

FROM base AS builder
# The venv gets no pip of its own: the base image's pip installs into it (pip --python).
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN pip --python /opt/venv/bin/python install -r /tmp/requirements.txt

FROM builder AS test
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /src
COPY requirements.txt requirements-dev.txt ./
RUN pip --python /opt/venv/bin/python install -r requirements-dev.txt
COPY pyproject.toml ./
COPY src ./src
COPY tests ./tests
RUN ruff check . && ruff format --check . && pytest -q

FROM base AS runtime
# The app does not need pip at runtime. Removing it shrinks the attack surface and also
# removes the libraries pip vendors (urllib3, msgpack, ...), which image scanners report.
RUN python -m pip uninstall --yes --quiet pip
COPY --from=builder /opt/venv /opt/venv
COPY src/sample_api /app/sample_api
WORKDIR /app

# Build metadata goes last, so a new commit does not invalidate the dependency layers.
ARG APP_VERSION=0.1.0
ARG GIT_COMMIT=unknown
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app \
    APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT}
LABEL org.opencontainers.image.source="https://github.com/Sameerkhan8/kubernetes-platform-starter" \
      org.opencontainers.image.title="sample-api" \
      org.opencontainers.image.description="Demo FastAPI service for kubernetes-platform-starter" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}"

# Files stay owned by root and read-only for the app user. The pod runs with
# readOnlyRootFilesystem; only /tmp (an emptyDir) is writable.
USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["python", "-m", "sample_api"]
