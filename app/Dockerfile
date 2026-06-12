# Stage 1: Builder
FROM python:3.12-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

COPY uv.lock pyproject.toml ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project

COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev

# Stage 2: Runtime
FROM python:3.12-slim

RUN groupadd --system --gid 1000 appuser \
 && useradd --system --gid 1000 --uid 1000 --create-home appuser

COPY --from=builder --chown=appuser:appuser /app /app

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_LEVEL=info

USER appuser
WORKDIR /app

EXPOSE 8000

CMD ["litestar", "run", "--host", "0.0.0.0", "--port", "8000"]
