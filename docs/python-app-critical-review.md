# Python App Critical Review

Date: 2026-06-15

Scope: `app/`, with emphasis on the Litestar application in `app/src/demo_app`, its database/migration setup, Docker packaging, and Helm deployment.

## Executive Summary

The app is a useful CNPG/Litestar demo, but it is not yet in a reliable state for repeatable deployment. The highest-risk issues are packaging and runtime drift: clean Docker builds depend on an ignored `uv.lock`, Docker images would include local-only state because there is no `.dockerignore`, tracing-enabled startup currently fails, and Kubernetes readiness reports success even when the database is unavailable.

The implementation also has a split architecture: DTO, repository, and service modules exist, but the active controllers bypass them and accept raw dictionaries. That keeps the demo small, but it leaves validation, typing, error handling, and tests weak.

## Findings

### P0: Clean Checkout Docker Builds Depend on an Ignored Lockfile

`app/Dockerfile:12` and `app/Dockerfile.dev:10` both run `COPY uv.lock pyproject.toml ./`, but `app/.gitignore:10` ignores `uv.lock`. The file exists locally, but `git ls-files app` does not include it.

Impact: a clean clone will not have `app/uv.lock`, so both production and dev Docker builds fail before dependency installation. This also makes dependency resolution non-repeatable across machines.

Recommendation: commit `app/uv.lock`, remove it from `app/.gitignore`, and keep Docker builds locked. If this is intentionally a library-style project, change the Dockerfiles to avoid `--locked`, but that is the weaker choice for a deployable app.

### P0: Tracing-Enabled App Startup Fails at Runtime

`app/src/demo_app/main.py:31` imports `SERVICE_NAME_ATTRIBUTE` from `opentelemetry.sdk.resources`, but the installed package does not export that name. Enabling tracing calls `setup_opentelemetry()` from `create_app()` at `main.py:76-77`, so `DEMO_APP_TRACING_ENABLED=true` crashes startup.

Verified with:

```bash
uv run python -c "from demo_app.main import create_app; from demo_app.config import AppSettings; create_app(AppSettings(tracing_enabled=True))"
```

Result: `ImportError: cannot import name 'SERVICE_NAME_ATTRIBUTE'`.

Impact: the planned v2 observability mode cannot boot.

Recommendation: use the current OpenTelemetry semantic-conventions API or literal resource key (`"service.name"`) consistently, then add a startup test that creates the app with tracing enabled.

### P1: Docker Build Context Will Include Local State and Generated Files

There is no `app/.dockerignore`, while both Dockerfiles use `COPY . .` (`app/Dockerfile:16`, `app/Dockerfile.dev:13`). The local app directory currently contains ignored files and directories such as `app/.venv/`, `app/src/demo_app/**/__pycache__/`, `app/SCRATCHPAD.md`, `app/TASK-QUEUE.md`, `app/WORKING.md`, `app/memory/`, `app/plans/`, and `app/knowledge/`.

Impact: image builds can become slow, non-reproducible, and potentially leak local notes or generated state into runtime images.

Recommendation: add `app/.dockerignore` covering `.venv`, caches, `__pycache__`, local planning/memory files, build artifacts, and compose data.

### P1: Readiness Probe Returns HTTP 200 on Database Failure

`app/src/demo_app/controllers/health.py:14-21` catches database exceptions and returns `{"status": "degraded", ...}` with the route status code still set to 200. The Helm readiness probe uses `/health/ready` (`app/helm/demo-app/templates/deployment.yaml:84-87`).

Impact: Kubernetes will continue routing traffic to pods that cannot reach PostgreSQL. This defeats readiness checks during DB outages, credential rotation mistakes, network-policy mistakes, and failed migrations.

Recommendation: raise an HTTP 503, return a `Response` with status 503, or split human-readable health from Kubernetes readiness.

### P1: Dynamic Database Credentials Are Rendered but Not Actually Used

The dynamic ExternalSecret template writes both `username` and `password` (`app/helm/demo-app/templates/secret-eso-dynamic.yaml:22-29`), but the Deployment always sets `DEMO_APP_DB_USER` from `.Values.database.user` (`app/helm/demo-app/templates/deployment.yaml:62-63`) and only reads the password from the Secret (`deployment.yaml:51-55`).

Impact: when `database.credentialsMode=dynamic`, Vault may issue a dynamic username, but the app still connects as static user `app`. Dynamic credentials will fail or silently not be exercised.

Recommendation: when dynamic mode is enabled, source both `DEMO_APP_DB_USER` and `DEMO_APP_DB_PASSWORD` from the target Secret.

### P1: Helm ConfigMap Is Rendered but Not Consumed

`app/helm/demo-app/templates/configmap.yaml` renders application settings, including `DEMO_APP_METRICS_ENABLED` (`configmap.yaml:8-18`), but the Deployment does not use `envFrom` or individual `configMapKeyRef` entries. Instead it duplicates most env vars inline (`app/helm/demo-app/templates/deployment.yaml:56-73`) and omits `DEMO_APP_METRICS_ENABLED`.

Impact: toggling `observability.metrics.enabled` controls PodMonitor rendering, but not whether the app exposes `/metrics`. Similar future ConfigMap settings can appear to work while being ignored.

Recommendation: either consume the ConfigMap from the Deployment or delete it and keep the env surface in one place.

### P1: API Input Is Unvalidated and Bypasses the Existing Service/DTO Layer

`app/src/demo_app/controllers/tasks.py:54-63` accepts a raw `dict` for create, defaults missing `title` to an empty string, and assigns values directly to SQLAlchemy fields. `tasks.py:86-88` updates any existing model attribute except `id`. The DTOs and service/repository layer in `app/src/demo_app/domain/tasks/` are not used by the active controllers.

Impact: invalid dates, bad priority values, empty titles, and unexpected attributes become runtime database or serialization errors instead of structured 4xx responses. The domain layer gives a false sense of architecture because it is not on the request path.

Recommendation: use Litestar DTOs/Pydantic/msgspec models for request bodies, validate task fields explicitly, and route both API and page handlers through one service path.

### P2: Database URL Construction Does Not Escape Credentials

`app/src/demo_app/config.py:53-56` and `config.py:75-78` interpolate username and password directly into PostgreSQL URLs.

Impact: Vault-generated or user-provided credentials containing `@`, `:`, `/`, `?`, `#`, or percent-sensitive characters can produce invalid or misparsed URLs. This matters more if dynamic secrets are enabled.

Recommendation: build URLs with SQLAlchemy `URL.create()` or URL-quote user/password components.

### P2: `db_schema` Is Configured but Unused

`app/src/demo_app/config.py:13` exposes `db_schema`, and Helm renders `DEMO_APP_DB_SCHEMA` in the ConfigMap, but the SQLAlchemy engine and migrations do not set `search_path` or schema-qualified metadata.

Impact: operators may set `DEMO_APP_DB_SCHEMA` expecting isolation, but all tables still land in `public`.

Recommendation: either remove the setting or wire it into SQLAlchemy/Alembic deliberately.

### P2: Migration Strategy Uses the Pooler in Kubernetes

The dev script intentionally runs migrations directly against Postgres and documents that DDL should bypass PgBouncer (`app/scripts/dev.sh:33-36`, `dev.sh:107-114`). The Helm Deployment uses the same `.Values.database.host` for runtime and migrations, which defaults to `pooler-demo-rw.demo-db.svc.cluster.local` (`app/helm/demo-app/values.yaml:10`, `app/helm/demo-app/templates/deployment.yaml:32-39`).

Impact: the Kubernetes path contradicts the local operational guidance. It may work in session mode, but it is fragile and will break if the pooler mode changes or if migration behavior needs direct server semantics.

Recommendation: add a separate migration host/URL value that points directly at the CNPG rw service, and keep app runtime traffic on the pooler.

### P2: Quality Gates Are Present but Currently Red

Commands run from `app/`:

```bash
uv run ruff check .
uv run mypy src
uv run pytest
helm lint app/helm/demo-app --set global.traefikIpDashed=172-18-255-200
helm template demo-app app/helm/demo-app --set global.traefikIpDashed=172-18-255-200
```

Results:

- Ruff failed with 63 issues, mostly import ordering, line length, unused imports, and modern type syntax.
- Mypy failed with 4 errors in `src/demo_app/main.py`; two are OpenTelemetry import/type issues and two come from the untyped `plugins = []` list being inferred as `list[SQLAlchemyPlugin]`.
- Pytest collected 0 tests.
- Helm lint passed.
- Helm template rendered successfully and confirmed the ConfigMap is not consumed by the Deployment.

Recommendation: add a small test suite around app creation, health readiness, task validation, and settings URL construction before expanding behavior.

## Lower-Risk Observations

- The homepage hard-codes version `"0.1.0"` in `app/src/demo_app/controllers/pages.py:29` instead of using `AppSettings` or app state.
- HTML forms perform create/update/delete without CSRF protection. That may be acceptable for a local demo, but the chart exposes the app through HTTPS ingress.
- NetworkPolicy is disabled by default. If enabled, the monitoring ingress rule targets a namespace named `monitoring`, while this repo's monitoring stack uses namespaces such as `prometheus-operator` and `grafana`.
- The `app.tracingEnabled` value in `app/helm/demo-app/values.yaml:32` appears unused; the active path is `observability.tracing.enabled`.

## Suggested Remediation Order

1. Commit `app/uv.lock` and add `app/.dockerignore`.
2. Fix tracing startup and add an app factory test with tracing enabled.
3. Change readiness failure to HTTP 503 and test it with a failing DB session.
4. Make Helm env handling single-source and fix dynamic credential username wiring.
5. Introduce request validation for task API/page writes and route through the existing service layer.
6. Decide whether `db_schema` is supported; implement it or remove it.
7. Bring Ruff and mypy to green, then add minimal integration tests.
