# Litestar Task Tracker App — Implementation Plan

A uv-managed Python application running in Kubernetes, backed by CNPG PostgreSQL, with full observability and two schema versions demonstrating database migration.

## 1. Overview

### Namespaces

| Namespace | Purpose |
|-----------|---------|
| `demo` | Production app deployment (v1 and v2) |
| `demo-dev` | In-cluster live development environment |
| `demo-db` | CNPG PostgreSQL cluster + PgBouncer pooler |

### Application Versions

| Version | Schema | Migration Strategy | Observability |
|---------|--------|--------------------|---------------|
| v1 | `tasks(id, title, done, created_at)` | Init container runs `litestar database upgrade` | Logs → Loki, Metrics → Mimir |
| v2 | adds `assignee`, `due_date`, `priority` columns | App startup runs `litestar database upgrade` | Logs → Loki, Metrics → Mimir, Traces → Tempo (OTel auto-instrumentation) |

### URLs

| Service | URL |
|---------|-----|
| App (prod) | `https://demo-demo.<traefik-ip-dashed>.sslip.io` |
| App (dev) | `https://demo-dev-demo.<traefik-ip-dashed>.sslip.io` |
| Metrics | `https://demo-demo.<traefik-ip-dashed>.sslip.io/metrics` |
| Health | `https://demo-demo.<traefik-ip-dashed>.sslip.io/health` |

---

## 2. Architecture

```mermaid
graph TB
    subgraph host["Host containers"]
        Vault["Vault\nPKI + secrets\n+ DB engine"]
        StepCA["step-ca\nRoot CA"]
        RustFS["RustFS\nS3 storage"]
    end

    subgraph k8s["Kind cluster (local)"]
        subgraph traefik_ns["traefik"]
            LB["Traefik LoadBalancer\nports 80/443"]
        end

        subgraph cert_mgr["cert-manager"]
            CI["ClusterIssuer\nvault-pki"]
            TM["trust-manager\nstep-ca-bundle"]
        end

        subgraph eso_ns["external-secrets"]
            ESO["ESO\nsyncs Vault → K8s Secrets"]
        end

        subgraph demo_db["demo-db"]
            CNPG["Cluster: demo\nPostgreSQL 18\n3 replicas"]
            Pooler["Pooler: pooler-demo-rw\nPgBouncer session mode"]
            ESSecrets["ExternalSecrets\n(static or dynamic creds)"]
        end

        subgraph demo_ns["demo"]
            AppV2["demo-app:v2\nLitestar + OTel auto-instrumentation\ninit: db-migrate"]
            Cert["Certificate\ndemo-demo (vault-pki)"]
            Ingress["IngressRoute\nHTTPS → app"]
            PM["PodMonitor\ncustom metrics"]
            Reloader["Secret-reload\nannotation"]
        end

        subgraph demo_dev["demo-dev"]
            AppDev["demo-app:dev\nLitestar (hot-reload)\nTilt sync"]
            CertDev["Certificate\ndemo-dev-demo (vault-pki)"]
            IngressDev["IngressRoute\nHTTPS → app"]
        end

        subgraph monitoring["grafana / mimir / tempo"]
            Alloy["Alloy\nlog scraper"]
            Mimir["Mimir\nmetrics"]
            Loki["Loki\nlogs"]
            Tempo["Tempo\ntraces"]
            Prom["Prometheus\nscrape → remoteWrite Mimir"]
            OTel["OTel Collector\ntraces → Tempo"]
        end
    end

    LB -->|"HTTPS"| Ingress
    LB -->|"HTTPS"| IngressDev
    Ingress --> AppV2
    IngressDev --> AppDev
    AppV2 -->|"pg://pooler-demo-rw"| Pooler
    AppDev -->|"pg://pooler-demo-rw"| Pooler
    Pooler --> CNPG
    StepCA --> TM
    Vault --> CI
    CI --> Cert
    CI --> CertDev
    Vault -->|"KV or DB Engine"| ESO
    ESO --> ESSecrets
    ESSecrets -->|"password sync\n+ cnpg.io/reload"| CNPG
    ESSecrets -->|"password update"| AppV2
    AppV2 -->|"stdout structured logs\n(trace_id, span_id)"| Alloy
    AppDev -->|"stdout structured logs"| Alloy
    AppV2 -->|"/metrics"| Prom
    AppDev -->|"/metrics"| Prom
    AppV2 -->|"OTel auto-instrumentation\n(ASGI, SQLAlchemy, asyncpg, logging, httpx)"| OTel
    Prom --> Mimir
    Alloy --> Loki
    OTel --> Tempo
    CNPG -->|"backup"| RustFS
```

---

## 3. Project Structure

```
app-v1/
├── pyproject.toml                    # uv project config
├── uv.lock                          # Lockfile (generated)
├── .python-version                  # Python version pin
├── Dockerfile                       # Multi-stage production build
├── Dockerfile.dev                   # Development image (uvicorn --reload)
├── src/
│   └── demo_app/
│       ├── __init__.py
│       ├── main.py                  # Litestar app factory
│       ├── config.py                # Settings via pydantic-settings
│       ├── db/
│       │   ├── __init__.py
│       │   ├── base.py              # SQLAlchemy declarative base
│       │   ├── models.py            # SQLAlchemy models (Task)
│       │   └── session.py           # SQLAlchemy async config
│       ├── migrations/              # Alembic migrations
│       │   ├── env.py               # Async migration environment
│       │   ├── script.py.mako
│       │   └── versions/
│       │       ├── 001_create_tasks.py   # v1 schema
│       │       └── 002_add_assignee_priority.py  # v2 schema
│       ├── domain/
│       │   ├── __init__.py
│       │   ├── tasks/
│       │   │   ├── __init__.py
│       │   │   ├── dto.py           # Data transfer objects
│       │   │   ├── repository.py    # Repository pattern
│       │   │   └── service.py       # Business logic
│       │   └── health/
│       │       ├── __init__.py
│       │       └── controller.py    # Health/version endpoints
│       ├── controllers/
│       │   ├── __init__.py
│       │   ├── tasks.py             # Task CRUD API
│       │   ├── pages.py             # HTML page controllers
│       │   └── health.py            # Health/readiness endpoints
│       ├── otel.py                  # OTel auto-instrumentation setup (v2)
│       ├── templates/               # Jinja2 HTML templates
│       │   ├── base.html            # Base layout
│       │   ├── index.html           # Landing page (version, DB status)
│       │   ├── tasks/
│       │   │   ├── list.html        # Task list with CRUD
│       │   │   ├── detail.html      # Task detail view
│       │   │   └── form.html        # Create/edit form
│       │   └── partials/
│       │       └── task_row.html    # HTMX partial (future)
│       └── static/                  # CSS, JS, favicon
│           └── style.css
├── k8s/                             # Raw K8s manifests (for reference)
│   ├── namespace-demo.yaml
│   ├── namespace-demo-dev.yaml
│   ├── namespace-demo-db.yaml
│   ├── certificate.yaml             # TLS certificate for app
│   ├── certificaterequest.yaml
│   └── podmonitor.yaml              # Prometheus PodMonitor
└── helm/
    └── demo-app/
        ├── Chart.yaml
        ├── values.yaml
        ├── values-dev.yaml           # Dev overlay values
        ├── templates/
        │   ├── _helpers.tpl
        │   ├── deployment.yaml
        │   ├── service.yaml
        │   ├── ingressroute.yaml     # Traefik IngressRoute
        │   ├── certificate.yaml       # cert-manager Certificate
        │   ├── podmonitor.yaml        # Prometheus PodMonitor
        │   ├── configmap.yaml         # App configuration
        │   ├── secret-eso.yaml          # ExternalSecret for static DB creds
        │   ├── secret-eso-dynamic.yaml  # ExternalSecret for dynamic Vault DB Engine creds
        │   ├── serviceaccount.yaml
        │   └── networkpolicy.yaml
        └── files/
            └── alloy-scrape.yaml     # Alloy scrape config (optional)

app-v2/
├── pyproject.toml                    # uv project config
├── uv.lock                          # Lockfile (generated)
├── .python-version                  # Python version pin
├── Dockerfile                       # Multi-stage production build
├── Dockerfile.dev                   # Development image (uvicorn --reload)
....
```

---

## 4. Application Design

### 4.1 pyproject.toml

```toml
[project]
name = "demo-app"
version = "0.1.0"
description = "Litestar task tracker demo app"
requires-python = ">=3.12"
dependencies = [
    "litestar[standard]>=2.12",
    "advanced-alchemy[litestar]>=1.0",
    "uvicorn[standard]>=0.32",
    "asyncpg>=0.30",
    "psycopg[binary]>=3.2",
    "pydantic-settings>=2.6",
    "jinja2>=3.1",
    "opentelemetry-api>=1.28",
    "opentelemetry-sdk>=1.28",
    "opentelemetry-exporter-otlp>=1.28",
    "opentelemetry-instrumentation-asgi>=0.49b0",
    "opentelemetry-instrumentation-sqlalchemy>=0.49b0",
    "opentelemetry-instrumentation-asyncpg>=0.49b0",
    "opentelemetry-instrumentation-logging>=0.49b0",
    "opentelemetry-instrumentation-httpx>=0.49b0",
    "opentelemetry-instrumentation-requests>=0.49b0",
    "opentelemetry-processor-baggage-spanprocessor>=0.49b0",
    "prometheus-client>=0.21",
]

[dependency-groups]
dev = [
    "pytest>=8.0",
    "pytest-asyncio>=0.24",
    "httpx>=0.28",
    "ruff>=0.8",
    "mypy>=1.13",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.litestar]
app = "demo_app.main:app"

[tool.ruff]
target-version = "py312"
```

### 4.2 Configuration (pydantic-settings)

```python
# src/demo_app/config.py
from pydantic_settings import BaseSettings, SettingsConfigDict

class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="DEMO_APP_")

    # Database — individual fields (used in K8s with secrets)
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "demo"
    db_user: str = "app"
    db_password: str = ""  # From ESO/Vault secret, or set locally
    db_schema: str = "public"

    # Database — full connection string override.
    # When set, takes priority over individual DB_* fields.
    # Supports: postgresql://user:pass@host:port/dbname (driver auto-detected)
    # Also accepts: postgresql+asyncpg:// or postgresql+psycopg:// explicitly
    database_url: str | None = None

    # Application
    app_version: str = "0.1.0"
    debug: bool = False
    log_level: str = "INFO"

    # Observability
    otlp_endpoint: str = "http://otel-collector.otel.svc.cluster.local:4317"
    metrics_enabled: bool = True
    tracing_enabled: bool = False  # v1: off, v2: on

    # Server
    host: str = "0.0.0.0"
    port: int = 8000

    @property
    def database_url_async(self) -> str:
        """Async database URL (asyncpg driver).

        Priority: DEMO_APP_DATABASE_URL > individual DEMO_APP_DB_* fields.
        If DATABASE_URL uses postgresql://, the driver is auto-replaced
        with postgresql+asyncpg://. If it already specifies a driver,
        it's used as-is.
        """
        if self.database_url:
            url = self.database_url
            if url.startswith("postgresql://"):
                url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
            url = url.replace("+psycopg://", "+asyncpg://", 1)
            url = url.replace("+psycopg2://", "+asyncpg://", 1)
            return url
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def database_url_sync(self) -> str:
        """Sync URL for Alembic migrations (psycopg driver).

        Priority: DEMO_APP_DATABASE_URL > individual DEMO_APP_DB_* fields.
        Always uses psycopg driver for sync operations.
        """
        if self.database_url:
            url = self.database_url
            if url.startswith("postgresql+asyncpg://"):
                url = url.replace("+asyncpg://", "+psycopg://", 1)
            elif url.startswith("postgresql://"):
                url = url.replace("postgresql://", "postgresql+psycopg://", 1)
            elif url.startswith("postgresql+psycopg2://"):
                url = url.replace("+psycopg2://", "+psycopg://", 1)
            return url
        return (
            f"postgresql+psycopg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )
```

### 4.3 Database Models

```python
# src/demo_app/db/models.py
from datetime import datetime
from sqlalchemy import String, Boolean, Integer, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column
from .base import Base


class Task(Base):
    """Task tracker model — v1 schema."""
    __tablename__ = "tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    done: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=datetime.now, nullable=False
    )

    # v2 columns (nullable for backward compatibility)
    assignee: Mapped[str | None] = mapped_column(String(255), nullable=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    priority: Mapped[int | None] = mapped_column(Integer, nullable=True)
```

### 4.4 Migrations

**v1 migration** (`001_create_tasks.py`):
```python
"""create tasks table

Revision ID: 001
Revises:
Create Date: 2025-01-01
"""
from alembic import op
import sqlalchemy as sa

revision = "001"
down_revision = None
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table(
        "tasks",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("title", sa.String(255), nullable=False),
        sa.Column("done", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

def downgrade() -> None:
    op.drop_table("tasks")
```

**v2 migration** (`002_add_assignee_priority.py`):
```python
"""add assignee, due_date, priority columns

Revision ID: 002
Revises: 001
Create Date: 2025-01-15
"""
from alembic import op
import sqlalchemy as sa

revision = "002"
down_revision = "001"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.add_column("tasks", sa.Column("assignee", sa.String(255), nullable=True))
    op.add_column("tasks", sa.Column("due_date", sa.DateTime(timezone=True), nullable=True))
    op.add_column("tasks", sa.Column("priority", sa.Integer(), nullable=True))

def downgrade() -> None:
    op.drop_column("tasks", "priority")
    op.drop_column("tasks", "due_date")
    op.drop_column("tasks", "assignee")
```

### 4.5 App Factory

```python
# src/demo_app/main.py
import os
from litestar import Litestar
from litestar.plugins.prometheus import PrometheusConfig, PrometheusController
from litestar.plugins.sqlalchemy import SQLAlchemyPlugin
from litestar.contrib.jinja import JinjaTemplateEngine
from litestar.template.config import TemplateConfig

from demo_app.config import AppSettings
from demo_app.db.session import get_sqlalchemy_config
from demo_app.controllers import tasks, pages, health


def setup_opentelemetry(settings: AppSettings) -> None:
    """Configure OTel auto-instrumentation for v2.

    Called before app creation so that instrumentors can wrap
    libraries at import time. Uses opentelemetry-instrument
    pattern programmatically rather than the CLI wrapper, which
    gives us control over which instrumentors are active.
    """
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource, SERVICE_NAME_ATTRIBUTE
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

    # Resource identifies this service in traces
    resource = Resource.create({
        SERVICE_NAME_ATTRIBUTE: "demo-app",
        "service.version": settings.app_version,
        "service.namespace": "demo",
    })

    provider = TracerProvider(resource=resource)
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint=settings.otlp_endpoint)
        )
    )
    trace.set_tracer_provider(provider)

    # Auto-instrument libraries — each wraps the library transparently
    from opentelemetry.instrumentation.asgi import ASGIInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
    from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    ASGIInstrumentor().instrument()           # Litestar ASGI middleware
    SQLAlchemyInstrumentor().instrument()      # Sync SQLAlchemy queries
    AsyncPGInstrumentor().instrument()         # Async PostgreSQL queries
    LoggingInstrumentor().instrument()         # Inject trace_id into log records
    HTTPXClientInstrumentor().instrument()     # Outbound HTTP calls


def create_app(settings: AppSettings | None = None) -> Litestar:
    settings = settings or AppSettings()

    # OpenTelemetry auto-instrumentation (v2 only)
    if settings.tracing_enabled:
        setup_opentelemetry(settings)

    plugins = []

    # SQLAlchemy
    alchemy_config = get_sqlalchemy_config(settings)
    plugins.append(SQLAlchemyPlugin(config=alchemy_config))

    # Prometheus
    prometheus_config = PrometheusConfig(
        app_name="demo_app",
        labels={"version": settings.app_version},
    )

    # OpenTelemetry plugin (adds Litestar-specific spans on top of auto-instrumentation)
    if settings.tracing_enabled:
        from litestar.plugins.opentelemetry import OpenTelemetryPlugin, OpenTelemetryConfig
        plugins.append(OpenTelemetryPlugin(OpenTelemetryConfig()))

    return Litestar(
        route_handlers=[
            tasks.TaskController,
            pages.PageController,
            health.HealthController,
            PrometheusController,
        ],
        plugins=plugins,
        template_config=TemplateConfig(
            directory="src/demo_app/templates",
            engine=JinjaTemplateEngine,
        ),
        on_startup=[_log_startup],
        on_shutdown=[_log_shutdown],
    )
```

### 4.6 HTML Interface

**Landing page** (`/`): Shows app version, DB connection status, links to `/metrics`, `/tasks`, and health endpoints.

**Task CRUD** (`/tasks`): List all tasks, create/edit/delete with HTML forms. Simple server-side rendered Jinja2 templates.

### 4.7 Health Endpoints

```python
# src/demo_app/controllers/health.py
from litestar import Controller, get
from sqlalchemy import text

class HealthController(Controller):
    path = "/health"

    @get(path="/", status_code=200)
    async def health(self) -> dict:
        return {"status": "healthy"}

    @get(path="/ready", status_code=200)
    async def ready(self, db_session: AsyncSession) -> dict:
        result = await db_session.execute(text("SELECT 1"))
        return {"status": "ready", "db": "connected"}

    @get(path="/startup", status_code=200)
    async def startup(self) -> dict:
        return {"status": "started"}
```

---

## 5. Database Setup

### 5.1 CNPG Cluster (`demo-db` namespace)

Following the existing `rbr-ver-db` pattern:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: demo
  namespace: demo-db
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie

  storage:
    size: 1Gi
  walStorage:
    size: 1Gi

  affinity:
    nodeSelector:
      node-role.kubernetes.io/postgres: ""
    tolerations:
    - key: node-role.kubernetes.io/postgres
      operator: Exists
      effect: NoSchedule

  enableSuperuserAccess: true
  superuserSecret:
    name: demo-superuser

  bootstrap:
    initdb:
      dataChecksums: true
      database: demo
      owner: app
      secret:
        name: demo-app
      # Post-bootstrap SQL to create readonly role
      postInitSQL:
        - CREATE ROLE readonly LOGIN;
        - GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;

  managed:
    roles:
    - name: app
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: demo-app
    - name: readonly
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: demo-readonly

  monitoring:
    enablePodMonitor: false
    disableDefaultQueries: false
    customQueriesConfigMap:
      - key: queries
        name: cnpg-default-monitoring

  certificates:
    serverAltDNSNames:
      - demo-demo-db.${TRAEFIK_IP_DASHED}.sslip.io

  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: objectstore-demo
      serverName: demo
```

### 5.2 PgBouncer Pooler

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pooler-demo-rw
  namespace: demo-db
spec:
  cluster:
    name: demo
  instances: 2
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "1000"
      default_pool_size: "10"
```

### 5.3 Database Credentials

**Two modes** (controlled by Helm values):

**Mode 1: Static credentials (ESO + Vault KV)**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: demo-app
  namespace: demo-db
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-approle
    kind: ClusterSecretStore
  target:
    name: demo-app
  data:
    - secretKey: username
      remoteRef:
        key: cnpg/demo/app
        property: username
    - secretKey: password
      remoteRef:
        key: cnpg/demo/app
        property: password
```

**Mode 2: Dynamic credentials (Vault DB Engine)** — future enhancement, same ExternalSecret pattern but pointing to Vault DB engine secrets.

### 5.4 Seeding

A Kubernetes Job runs after the CNPG cluster is ready:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: demo-db-seed
  namespace: demo-db
spec:
  template:
    spec:
      containers:
      - name: seed
        image: demo-app:latest
        command: ["python", "-m", "demo_app.seed"]
        env:
        - name: DEMO_APP_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: demo-app
              key: password
      restartPolicy: OnFailure
```

The seed script inserts ~20 sample tasks with varied states (done/not done, with/without assignee, different priorities).

---

## 6. Helm Chart

### 6.1 Chart.yaml

```yaml
apiVersion: v2
name: demo-app
description: Litestar task tracker demo application
type: application
version: 0.1.0
appVersion: "0.1.0"
maintainers:
  - name: cnpg-playground
```

### 6.2 values.yaml

```yaml
replicaCount: 2

image:
  repository: demo-app
  tag: ""  # Defaults to .Chart.AppVersion
  pullPolicy: IfNotPresent

# Database connection
database:
  host: "pooler-demo-rw.demo-db.svc.cluster.local"
  port: 5432
  name: "demo"
  user: "app"
  passwordSecret: "demo-app"
  passwordSecretKey: "password"
  schema: "public"
  # Secret rotation
  credentialsMode: "static"  # "static" or "dynamic"
  staticSecret:
    refreshInterval: 5m
    vaultPath: "cnpg/demo/app"
  dynamicSecret:
    refreshInterval: 30m
    vaultPath: "database/creds/demo-app"
    ttl: "1h"

# Application settings
app:
  version: "0.1.0"
  debug: false
  logLevel: "INFO"
  tracingEnabled: false

# Observability
observability:
  metrics:
    enabled: true
    path: /metrics
  tracing:
    enabled: false  # Set to true for v2
    otlpEndpoint: "http://otel-collector.otel.svc.cluster.local:4317"

# Migration strategy
migration:
  strategy: "initContainer"  # "initContainer" for v1, "startup" for v2

# TLS
tls:
  enabled: true
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  dnsNames:
    - "demo-demo.{{ .Values.global.traefikIpDashed }}.sslip.io"

# Ingress
ingress:
  enabled: true
  entryPoint: websecure
  tls: true

# Resources
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

# Global values (overridden per environment)
global:
  traefikIpDashed: ""

# ExternalSecret for DB credentials
externalSecret:
  enabled: true
  refreshInterval: 5m
  secretStoreRef:
    name: vault-approle
    kind: ClusterSecretStore
  data:
    - secretKey: password
      remoteRef:
        key: cnpg/demo/app
        property: password
  # Rotation: annotate deployment for auto-reload
  reloadOnUpdate: true
```

### 6.3 values-dev.yaml (Dev Overlay)

```yaml
replicaCount: 1

image:
  tag: "dev"
  pullPolicy: Always

app:
  debug: true
  logLevel: "DEBUG"
  tracingEnabled: false

migration:
  strategy: "startup"

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 250m
    memory: 128Mi

tls:
  dnsNames:
    - "demo-dev-demo.{{ .Values.global.traefikIpDashed }}.sslip.io"
```

### 6.4 Key Templates

**Deployment** (with migration init container for v1, auto-instrumentation for v2):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  annotations:
    reloader.stakater.com/auto: "true"  # Auto-reload on secret changes
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    metadata:
      annotations:
        # Force pod restart when DB secret changes
        secret-hash: {{ .Values.database.passwordSecret | sha256sum }}
    spec:
      {{- if eq .Values.migration.strategy "initContainer" }}
      initContainers:
      - name: db-migrate
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        command: ["litestar", "database", "upgrade"]
        env:
        - name: DEMO_APP_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ .Values.database.passwordSecret }}
              key: {{ .Values.database.passwordSecretKey }}
        # ... other env vars
      {{- end }}
      containers:
      - name: app
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        {{- if eq .Values.migration.strategy "startup" }}
        command: ["sh", "-c", "litestar database upgrade && litestar run --host 0.0.0.0 --port 8000"]
        {{- else }}
        command: ["litestar", "run", "--host", "0.0.0.0", "--port", "8000"]
        {{- end }}
        env:
        - name: DEMO_APP_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ .Values.database.passwordSecret }}
              key: {{ .Values.database.passwordSecretKey }}
        - name: DEMO_APP_TRACING_ENABLED
          value: {{ .Values.observability.tracing.enabled | quote }}
        - name: DEMO_APP_OTLP_ENDPOINT
          value: {{ .Values.observability.tracing.otlpEndpoint }}
        # ... other env vars
        ports:
        - containerPort: 8000
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
        startupProbe:
          httpGet:
            path: /health/startup
            port: 8000
          failureThreshold: 30
          periodSeconds: 2
        resources:
          {{- toYaml .Values.resources | nindent 12 }}
```

**Traefik IngressRoute**:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: demo-app
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`demo-demo.{{ .Values.global.traefikIpDashed }}.sslip.io`)
      kind: Rule
      services:
        - name: demo-app
          port: 8000
  tls:
    secretName: demo-app-tls
```

**PodMonitor**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: demo-app
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: demo-app
  podMetricsEndpoints:
    - port: http
      path: /metrics
      interval: 15s
```

---

## 7. Docker Build

### 7.1 Production Dockerfile (Multi-stage)

```dockerfile
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
```

### 7.2 Development Dockerfile

```dockerfile
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=0 \
    UV_LINK_MODE=copy

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --locked

COPY . .

EXPOSE 8000

CMD ["uvicorn", "demo_app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--reload"]
```

---

## 8. Tilt Configuration

### 8.1 Tiltfile

```python
# -*- mode: Starlark -*-

allow_k8s_contexts('kind-kind')

# Build the app image
docker_build(
    'demo-app',
    context='.',
    dockerfile='Dockerfile.dev',
    live_update=[
        sync('./src/demo_app', '/app/src/demo_app'),
        run('cd /app && uv sync', trigger=['./pyproject.toml', './uv.lock']),
    ]
)

# Deploy via Helm
helm_values = [
    './helm/demo-app/values-dev.yaml',
    '--set', 'global.traefikIpDashed=' + os.environ.get('TRAEFIK_IP_DASHED', '172-18-255-200'),
    '--set', 'image.tag=dev',
    '--set', 'image.pullPolicy=Always',
]

k8s_yaml(helm('./helm/demo-app', values=helm_values))

# Also deploy DB dependencies (CNPG cluster, pooler, secrets)
k8s_yaml([
    './k8s/namespace-demo.yaml',
    './k8s/namespace-demo-dev.yaml',
    './k8s/namespace-demo-db.yaml',
])

# Port forward for local development
k8s_resource('demo-app', port_forwards='8000:8000')
```

---

## 9. Local Development

### 9.1 Overview

The app supports local development with Docker Compose providing PostgreSQL, PgBouncer, and pgAdmin — matching the production topology (app → PgBouncer → PostgreSQL).

### 9.2 Configuration: DATABASE_URL

The `AppSettings` class supports two modes for database configuration:

**Mode 1: Single connection string (recommended for local dev)**

```bash
export DEMO_APP_DATABASE_URL="postgresql://app:app_password@localhost:6432/demo"
```

When `DEMO_APP_DATABASE_URL` is set, it takes priority over individual `DEMO_APP_DB_*` fields. The driver is auto-detected:
- `postgresql://` → `postgresql+asyncpg://` (for async) / `postgresql+psycopg://` (for sync/Alembic)
- `postgresql+asyncpg://` → used as-is for async, converted to `+psycopg://` for sync
- `postgresql+psycopg://` → converted to `+asyncpg://` for async, used as-is for sync

**Mode 2: Individual fields (used in K8s with secrets)**

```bash
export DEMO_APP_DB_HOST=pooler-demo-rw.demo-db.svc.cluster.local
export DEMO_APP_DB_PORT=5432
export DEMO_APP_DB_NAME=demo
export DEMO_APP_DB_USER=app
export DEMO_APP_DB_PASSWORD=secret
```

### 9.3 Docker Compose Services

| Service | Port | Purpose |
|---------|------|---------|
| PostgreSQL | 5432 | Direct database access (superuser) |
| PgBouncer | 6432 | Connection pooler (app connects here) |
| pgAdmin | 5050 | Web UI for database management |

**Connection strings:**

| Purpose | URL |
|---------|-----|
| App (via PgBouncer) | `postgresql://app:app_password@localhost:6432/demo` |
| Direct PostgreSQL | `postgresql://postgres:postgres_secret@localhost:5432/demo` |
| pgAdmin | `http://localhost:5050` (admin@example.com / pgadmin_secret) |

### 9.4 dev.sh Script

The `scripts/dev.sh` script provides a complete local development workflow:

```bash
./scripts/dev.sh up        # Start PostgreSQL, PgBouncer, pgAdmin
./scripts/dev.sh migrate   # Run Alembic migrations
./scripts/dev.sh seed      # Seed database with sample data
./scripts/dev.sh run       # Start Litestar dev server with hot-reload
./scripts/dev.sh all       # up + migrate + seed + run (full setup)
./scripts/dev.sh down      # Stop all services
./scripts/dev.sh reset     # Stop services and remove all data
./scripts/dev.sh status    # Show service status
```

### 9.5 Quick Start

```bash
cd app

# Start database services
./scripts/dev.sh up

# Run migrations and seed data
./scripts/dev.sh migrate
./scripts/dev.sh seed

# Start the app (with DATABASE_URL set automatically)
./scripts/dev.sh run
```

Or in one command:

```bash
./scripts/dev.sh all
```

### 9.6 Connecting to an Existing Database

If you already have PostgreSQL running locally, skip Docker Compose and set the connection string directly:

```bash
export DEMO_APP_DATABASE_URL="postgresql://myuser:mypass@localhost:5432/mydb"
uv run litestar database upgrade   # Run migrations
uv run python -m demo_app.seed    # Seed data
uv run uvicorn demo_app.main:create_app --factory --host 0.0.0.0 --port 8000 --reload
```

### 9.7 Docker Compose File

Located at `app/compose.yaml`:

```yaml
services:
  postgres:
    image: postgres:18-alpine
    container_name: demo-postgres
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres_secret
      POSTGRES_DB: demo
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - demo-net

  pgbouncer:
    image: edoburu/pgbouncer:latest
    container_name: demo-pgbouncer
    environment:
      DATABASE_URL: "postgres://app:app_password@postgres:5432/demo"
      PGBOUNCER_POOL_MODE: "session"
      PGBOUNCER_MAX_CLIENT_CONN: "1000"
      PGBOUNCER_DEFAULT_POOL_SIZE: "10"
    ports:
      - "6432:5432"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -p 5432"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - demo-net

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: demo-pgadmin
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: pgadmin_secret
    ports:
      - "5050:80"
    volumes:
      - ./docker/pgadmin_servers.json:/pgadmin4/servers.json:ro
      - ./docker/pgadmin_pgpass:/pgadmin4/pgpass:ro
    depends_on:
      pgbouncer:
        condition: service_healthy
    networks:
      - demo-net

volumes:
  pgdata:
    driver: local

networks:
  demo-net:
    driver: bridge
```

### 9.8 pgAdmin Configuration

Pre-configured server connections in `app/docker/pgadmin_servers.json`:

- **Demo (via PgBouncer)** — connects through the pooler on port 5432 (mapped to host 6432)
- **Demo (direct PG)** — connects directly to PostgreSQL on port 5432

Password file `app/docker/pgadmin_pgpass` provides auto-login for both connections.

---

## 10. Observability Integration

### 10.1 Structured Logging (v1+)

Litestar's `StructlogPlugin` outputs structured JSON logs to stdout. Alloy already scrapes all pod logs cluster-wide (see `monitoring/alloy/alloy-config.river`), so no additional configuration is needed — the app's stdout logs will automatically appear in Loki with labels:

```
{namespace="demo", pod="demo-app-xxx", container="app", app="demo-app"}
```

### 10.2 Prometheus Metrics (v1+)

The `PrometheusPlugin` exposes `/metrics` with standard HTTP metrics:

- `litestar_requests_total` — request count by method, path, status
- `litestar_request_duration_seconds` — request latency histogram
- `litestar_requests_in_progress` — concurrent requests

A `PodMonitor` resource tells Prometheus to scrape the app. Prometheus remote-writes to Mimir.

### 10.3 OpenTelemetry Tracing with Auto-Instrumentation (v2)

v2 uses **OTel auto-instrumentation** — libraries are wrapped transparently at startup without manual span creation in application code. This gives full distributed tracing coverage with zero per-endpoint boilerplate.

#### Auto-Instrumented Libraries

| Library | Instrumentor | What it traces |
|---------|-------------|----------------|
| Litestar (ASGI) | `ASGIInstrumentor` | HTTP request/response spans with method, URL, status |
| SQLAlchemy (sync) | `SQLAlchemyInstrumentor` | SQL query spans with statement text |
| asyncpg | `AsyncPGInstrumentor` | Async PostgreSQL query spans |
| Python logging | `LoggingInstrumentor` | Injects `trace_id` and `span_id` into log records |
| httpx | `HTTPXClientInstrumentor` | Outbound HTTP client spans |

#### How it works

1. **App startup** calls `setup_opentelemetry()` before creating the Litestar app
2. Each instrumentor wraps its target library, creating spans automatically
3. The `OpenTelemetryPlugin` adds Litestar-specific middleware on top (route info, guards, events)
4. All spans are batched and exported via OTLP gRPC to the in-cluster OTel Collector
5. The OTel Collector forwards to Tempo with tail-based sampling

#### Configuration

Controlled by `DEMO_APP_TRACING_ENABLED` environment variable:
- v1: `false` — no tracing, no overhead
- v2: `true` — full auto-instrumentation

The OTLP endpoint is configurable via `DEMO_APP_OTLP_ENDPOINT` (default: `http://otel-collector.otel.svc.cluster.local:4317`).

#### Log-Trace Correlation

When tracing is enabled, `LoggingInstrumentor` injects `trace_id` and `span_id` into every structured log record. This enables:
- Clicking from a Grafana log line directly to the trace in Tempo
- Filtering Loki logs by trace ID
- Correlating slow requests in metrics with their full trace

#### Resource Attributes

Every trace includes service metadata:
```python
resource = Resource.create({
    "service.name": "demo-app",
    "service.version": settings.app_version,
    "service.namespace": "demo",
})
```

This allows filtering traces by service, version, and namespace in Grafana/Tempo.

---

## 11. TLS/PKI Integration

The app uses the existing step-ca → cert-manager PKI chain:

1. **Certificate CR** in `demo` namespace requests a TLS cert from `vault-pki` ClusterIssuer
2. **cert-manager** issues a cert signed by Vault's intermediate CA
3. **Traefik** terminates TLS using this cert
4. **trust-manager** distributes the step-ca root+intermediate bundle to all namespaces

The app pod itself speaks plain HTTP on port 8000. Traefik handles TLS termination.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-app-tls
  namespace: demo
spec:
  secretName: demo-app-tls
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  dnsNames:
    - demo-demo.172-18-255-200.sslip.io
```

---

## 12. Secret Rotation

CNPG and ESO work together to enable zero-downtime credential rotation. When Vault rotates a password, ESO syncs the new secret into Kubernetes, and CNPG detects the change and rolls the pods.

### 12.1 Rotation Flow

```mermaid
sequenceDiagram
    participant Vault as Vault KV
    participant ESO as External Secrets Operator
    participant K8s as Kubernetes Secret
    participant CNPG as CNPG Cluster
    participant App as demo-app Pod

    Vault->>ESO: Password rotated (TTL or manual)
    ESO->>K8s: Update Secret with new password
    K8s->>CNPG: cnpg.io/reload annotation detected
    CNPG->>CNPG: Rolling restart of PostgreSQL pods
    Note over CNPG: New password takes effect
    K8s->>App: Secret volume/env updated
    App->>App: Reconnect with new credentials
```

### 12.2 ESO Configuration for Rotation

The ExternalSecret for the `app` user is configured with a short refresh interval and a reload trigger:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: demo-app
  namespace: demo-db
  annotations:
    # Trigger CNPG rolling update when secret changes
    reloader.stakater.com/auto: "true"
spec:
  refreshInterval: 5m    # Check Vault every 5 minutes
  secretStoreRef:
    name: vault-approle
    kind: ClusterSecretStore
  target:
    name: demo-app
    template:
      type: Opaque
      data:
        username: "{{ .username }}"
        password: "{{ .password }}"
  data:
    - secretKey: username
      remoteRef:
        key: cnpg/demo/app
        property: username
    - secretKey: password
      remoteRef:
        key: cnpg/demo/app
        property: password
```

### 12.3 CNPG Secret Rotation Detection

CNPG watches the secrets it references. When the `demo-app` secret is updated by ESO, CNPG automatically:

1. Detects the secret change
2. Updates the PostgreSQL role password
3. Rolls the application pods that reference the secret (if annotated)

The CNPG cluster manifest includes the `managed.roles` section which references the secret:

```yaml
managed:
  roles:
    - name: app
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: demo-app  # CNPG watches this secret
```

### 12.4 Application Pod Rotation

The demo-app Deployment includes the `secret-reload` annotation pattern. When the secret changes, the pods are rolled:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  template:
    metadata:
      annotations:
        # Force pod restart when secret changes
        secret-demo-app-hash: "{{ .Values.secretHash }}"
    spec:
      containers:
      - name: app
        env:
        - name: DEMO_APP_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: demo-app
              key: password
              # Optional: use optional field to allow startup before secret exists
```

### 12.5 Two Credential Modes

**Mode 1: Static credentials (default)** — Vault KV stores a fixed username/password. ESO syncs it to K8s. Rotation requires manually updating Vault KV, then ESO syncs and CNPG rolls.

**Mode 2: Dynamic credentials (Vault DB Engine)** — Vault Database Engine generates short-lived credentials (1h TTL). ESO syncs the current valid credential to K8s. When the credential approaches expiry, Vault generates a new one and ESO syncs it. This requires:

```yaml
# Vault DB Engine configuration (applied via Vault policies)
path "database/creds/demo-app" {
  capabilities = ["read"]
}
```

```yaml
# ExternalSecret pointing to Vault DB Engine
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: demo-app-dynamic
  namespace: demo-db
spec:
  refreshInterval: 30m   # Refresh before 1h TTL expires
  secretStoreRef:
    name: vault-approle
    kind: ClusterSecretStore
  target:
    name: demo-app
  data:
    - secretKey: username
      remoteRef:
        key: database/creds/demo-app
        property: username
    - secretKey: password
      remoteRef:
        key: database/creds/demo-app
        property: password
```

The Helm chart supports both modes via `values.yaml`:

```yaml
# values.yaml
database:
  credentialsMode: "static"  # "static" or "dynamic"
  staticSecret:
    refreshInterval: 5m
    vaultPath: "cnpg/demo/app"
  dynamicSecret:
    refreshInterval: 30m
    vaultPath: "database/creds/demo-app"
    ttl: "1h"
```

### 12.6 SQLAlchemy Connection Resilience for Rotation

When credentials rotate, existing DB connections may fail. The SQLAlchemy session config handles this gracefully:

```python
# src/demo_app/db/session.py
from advanced_alchemy.extensions.litestar import SQLAlchemyAsyncConfig, AsyncSessionConfig
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy.pool import AsyncAdaptedQueuePool

engine_config = {
    "pool_size": 5,
    "max_overflow": 10,
    "pool_pre_ping": True,        # Verify connections before use
    "pool_recycle": 300,          # Recycle connections every 5 min
    "pool_timeout": 30,           # Wait up to 30s for a connection
    "connect_args": {
        "statement_timeout": 30,  # PgBouncer-friendly
    },
}
```

`pool_pre_ping=True` ensures that stale connections (from rotated credentials) are detected and replaced before the application tries to use them, preventing `Authentication failed` errors during rotation.

---

## 13. Deployment Workflow

### 13.1 v1 Deployment

```bash
# 1. Create namespaces
kubectl apply -f k8s/namespace-demo.yaml
kubectl apply -f k8s/namespace-demo-db.yaml

# 2. Deploy CNPG cluster (with static credentials)
envsubst < k8s/cluster-demo.yaml.tpl | kubectl apply -f -

# 3. Wait for cluster ready
kubectl wait cluster/demo -n demo-db --for=condition=Ready --timeout=300s

# 4. Deploy app via Helm (v1)
helm upgrade --install demo-app ./helm/demo-app \
  --namespace demo \
  --set global.traefikIpDashed=172-18-255-200 \
  --set image.tag=v1 \
  --set migration.strategy=initContainer \
  --set observability.tracing.enabled=false
```

### 13.2 v2 Deployment (Upgrade)

```bash
# Upgrade to v2 with tracing enabled
helm upgrade demo-app ./helm/demo-app \
  --namespace demo \
  --set global.traefikIpDashed=172-18-255-200 \
  --set image.tag=v2 \
  --set migration.strategy=startup \
  --set observability.tracing.enabled=true
```

### 13.3 Development (Tilt)

```bash
# Start Tilt for live development
tilt up
```

---

## 14. Suggested Improvements

### 14.1 High Priority

1. **HTMX for progressive enhancement** — The HTML interface should use HTMX for dynamic updates without full page reloads. Litestar has first-class HTMX support via `HTMXPlugin`. This makes the CRUD interface feel responsive without writing JavaScript.

2. **Database seeding as a Helm hook** — Instead of a separate Job, use a Helm post-install hook (`helm.sh/hook: post-install`) for seeding. This ensures seeding runs after the CNPG cluster is ready and the app has run migrations.

3. **Alembic migration locking** — When running migrations as init container with multiple replicas, add `SELECT pg_advisory_lock(12345)` before running `alembic upgrade head` to prevent concurrent migration attempts. Alternatively, use a Kubernetes LeaderForElection pattern.

4. **Network policies** — Add NetworkPolicy resources to restrict traffic:
   - App pods can only reach PgBouncer on port 5432
   - Only Traefik can reach app on port 8000
   - Only Prometheus can scrape `/metrics`

5. **Security context** — Run as non-root user (already in Dockerfile), add `readOnlyRootFilesystem: true`, drop all capabilities, set `runAsNonRoot: true`.

6. **PodDisruptionBudget** — Ensure availability during node drains:
   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: demo-app
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         app.kubernetes.io/name: demo-app
   ```

### 14.2 Medium Priority

7. **HorizontalPodAutoscaler** — Scale based on CPU/memory or custom metrics (request rate):
   ```yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: demo-app
   spec:
     minReplicas: 2
     maxReplicas: 5
     metrics:
     - type: Resource
       resource:
         name: cpu
         target:
           type: Utilization
           averageUtilization: 70
   ```

8. **Custom Prometheus metrics** — Beyond the default Litestar HTTP metrics, add:
   - `demo_tasks_total` — counter of tasks by status
   - `demo_tasks_created_total` — counter of new tasks
   - `demo_db_connection_pool_size` — SQLAlchemy pool metrics

9. **Log correlation with traces** — Configure Structlog to include `trace_id` and `span_id` in log output. This enables clicking from a Grafana log line directly to the trace in Tempo.

10. **Database connection resilience** — Configure SQLAlchemy pool with:
    - `pool_pre_ping=True` — verify connections before use
    - `pool_size=5` — reasonable pool size for K8s
    - `max_overflow=10` — allow burst connections
    - `pool_recycle=300` — recycle connections every 5 minutes (PgBouncer friendly)

11. **Graceful shutdown** — Configure uvicorn with `--timeout-graceful-shutdown 30` to drain in-flight requests before terminating. Set `terminationGracePeriodSeconds: 60` in the Deployment.

12. **Versioned API prefix** — Use `/api/v1/tasks` instead of `/tasks` for the API endpoints. The HTML interface can use `/tasks` for user-facing URLs, but the API should be versioned for future compatibility.

### 14.3 Lower Priority

13. **Canary deployments** — Use Flagger or Argo Rollouts for progressive delivery of v2, automatically promoting when metrics are healthy.

14. **Database backup integration** — Add a ScheduledBackup CR and ObjectStore CR for the demo cluster, following the existing `rbr-ver-db` pattern with Barman Cloud Plugin.

15. **Container image scanning** — Add Trivy or Grype scanning to the CI pipeline.

16. **Read-only database replica** — Add a read-only pooler (`pooler-demo-ro`) for read-heavy workloads, and configure Litestar to route reads to the replica.

17. **CORS configuration** — If the API will be accessed from browser-based SPAs or external tools, configure CORS in Litestar.

18. **Rate limiting** — Litestar has built-in rate limiting. Add it for the API endpoints to prevent abuse.

---

## 15. Implementation Phases

### Phase 1: Foundation (v1 — no tracing)

1. Create project structure with `uv init`
2. Implement Litestar app with SQLAlchemy models (v1 schema)
3. Create Alembic migration for v1 schema
4. Build Dockerfile (multi-stage)
5. Create Helm chart (basic deployment + service)
6. Create CNPG cluster manifests
7. Deploy and verify v1 works end-to-end
8. Add HTML landing page and task CRUD
9. Add Prometheus metrics
10. Add structured logging
11. Add TLS certificate + IngressRoute
12. Add PodMonitor
13. Seed database

### Phase 2: Observability & Secret Rotation (v2 — add tracing)

1. Add v2 Alembic migration (assignee, due_date, priority columns)
2. Update HTML templates for v2 fields
3. Add OTel auto-instrumentation (ASGI, SQLAlchemy, asyncpg, logging, httpx)
4. Switch migration strategy from init container to app startup
5. Verify traces appear in Tempo via Grafana
6. Verify log-trace correlation in Loki (trace_id/span_id in structured logs)
7. Configure ESO ExternalSecret with rotation (5m refresh for static, 30m for dynamic)
8. Add `reloader.stakater.com/auto` annotation to Deployment for secret-triggered rollouts
9. Test secret rotation: update Vault KV → ESO syncs → CNPG rolls → app reconnects
10. Configure SQLAlchemy `pool_pre_ping=True` for graceful credential rotation

### Phase 3: Developer Experience

1. Create Tiltfile for live development
2. Create dev Dockerfile with hot-reload
3. Create dev values overlay
4. Test live development workflow

### Phase 4: Hardening

1. Add NetworkPolicy
2. Add security context (non-root, read-only FS)
3. Add PodDisruptionBudget
4. Add HPA
5. Add custom Prometheus metrics
6. Add log-trace correlation
7. Add graceful shutdown
8. Add database connection resilience
9. Add versioned API prefix

---

## 16. File Checklist

### Must Create

- [ ] `app/pyproject.toml`
- [ ] `app/src/demo_app/__init__.py`
- [ ] `app/src/demo_app/main.py`
- [ ] `app/src/demo_app/config.py`
- [ ] `app/src/demo_app/db/__init__.py`
- [ ] `app/src/demo_app/db/base.py`
- [ ] `app/src/demo_app/db/models.py`
- [ ] `app/src/demo_app/db/session.py` (with pool_pre_ping and rotation resilience)
- [ ] `app/src/demo_app/migrations/env.py`
- [ ] `app/src/demo_app/migrations/script.py.mako`
- [ ] `app/src/demo_app/migrations/versions/001_create_tasks.py`
- [ ] `app/src/demo_app/migrations/versions/002_add_assignee_priority.py`
- [ ] `app/src/demo_app/domain/tasks/dto.py`
- [ ] `app/src/demo_app/domain/tasks/repository.py`
- [ ] `app/src/demo_app/domain/tasks/service.py`
- [ ] `app/src/demo_app/domain/health/controller.py`
- [ ] `app/src/demo_app/controllers/tasks.py`
- [ ] `app/src/demo_app/controllers/pages.py`
- [ ] `app/src/demo_app/controllers/health.py`
- [ ] `app/src/demo_app/otel.py` (auto-instrumentation setup)
- [ ] `app/src/demo_app/templates/base.html`
- [ ] `app/src/demo_app/templates/index.html`
- [ ] `app/src/demo_app/templates/tasks/list.html`
- [ ] `app/src/demo_app/templates/tasks/detail.html`
- [ ] `app/src/demo_app/templates/tasks/form.html`
- [ ] `app/src/demo_app/static/style.css`
- [ ] `app/src/demo_app/seed.py`
- [ ] `app/Dockerfile`
- [ ] `app/Dockerfile.dev`
- [ ] `app/helm/demo-app/Chart.yaml`
- [ ] `app/helm/demo-app/values.yaml`
- [ ] `app/helm/demo-app/values-dev.yaml`
- [ ] `app/helm/demo-app/templates/_helpers.tpl`
- [ ] `app/helm/demo-app/templates/deployment.yaml`
- [ ] `app/helm/demo-app/templates/service.yaml`
- [ ] `app/helm/demo-app/templates/ingressroute.yaml`
- [ ] `app/helm/demo-app/templates/certificate.yaml`
- [ ] `app/helm/demo-app/templates/podmonitor.yaml`
- [ ] `app/helm/demo-app/templates/configmap.yaml`
- [ ] `app/helm/demo-app/templates/secret-eso.yaml`          # ExternalSecret for static DB creds
- [ ] `app/helm/demo-app/templates/secret-eso-dynamic.yaml`  # ExternalSecret for dynamic Vault DB Engine creds
- [ ] `app/helm/demo-app/templates/serviceaccount.yaml`
- [ ] `app/helm/demo-app/templates/networkpolicy.yaml`
- [ ] `app/helm/demo-app/templates/pdb.yaml`
- [ ] `app/k8s/namespace-demo.yaml`
- [ ] `app/k8s/namespace-demo-dev.yaml`
- [ ] `app/k8s/namespace-demo-db.yaml`
- [ ] `app/k8s/cluster-demo.yaml.tpl`
- [ ] `app/k8s/pooler-demo.yaml`
- [ ] `app/k8s/externalsecret-demo-app.yaml`
- [ ] `app/k8s/externalsecret-demo-readonly.yaml`
- [ ] `app/k8s/externalsecret-demo-superuser.yaml`
- [ ] `app/k8s/objectstore-demo.yaml.tpl`
- [ ] `app/k8s/scheduledbackup-demo.yaml`
- [ ] `app/Tiltfile`
- [ ] `app/scripts/setup.sh`
- [ ] `app/scripts/teardown.sh`
- [ ] `app/scripts/dev.sh`                          # Local dev workflow script
- [ ] `app/compose.yaml`                            # Docker Compose for local dev (PG + PgBouncer + pgAdmin)
- [ ] `app/docker/pgadmin_servers.json`             # pgAdmin pre-configured server connections
- [ ] `app/docker/pgadmin_pgpass`                   # pgAdmin password file