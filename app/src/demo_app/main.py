import logging

from litestar import Litestar
from litestar.datastructures import State
from litestar.plugins.prometheus import PrometheusConfig, PrometheusController
from litestar.plugins.structlog import StructlogPlugin
from litestar.contrib.jinja import JinjaTemplateEngine
from litestar.static_files.config import StaticFilesConfig
from litestar.template.config import TemplateConfig

from demo_app.config import AppSettings
from demo_app.db.session import get_sqlalchemy_config
from demo_app.controllers.tasks import TaskController
from demo_app.controllers.pages import PageController
from demo_app.controllers.health import HealthController

logger = logging.getLogger(__name__)


def setup_opentelemetry(settings: AppSettings) -> None:
    """Configure OTel auto-instrumentation for v2.

    Called before app creation so that instrumentors can wrap
    libraries at import time.
    """
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource, SERVICE_NAME_ATTRIBUTE
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

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

    from opentelemetry.instrumentation.asgi import ASGIInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
    from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    ASGIInstrumentor().instrument()
    SQLAlchemyInstrumentor().instrument()
    AsyncPGInstrumentor().instrument()
    LoggingInstrumentor().instrument()
    HTTPXClientInstrumentor().instrument()


async def _log_startup(app: Litestar) -> None:
    """Log application startup."""
    logger.info("demo-app v%s starting", app.state.get("version", "unknown"))


async def _log_shutdown(app: Litestar) -> None:
    """Log application shutdown."""
    logger.info("demo-app shutting down")


def create_app(settings: AppSettings | None = None) -> Litestar:
    """Create and configure the Litestar application."""
    settings = settings or AppSettings()

    # OpenTelemetry auto-instrumentation (v2 only)
    if settings.tracing_enabled:
        setup_opentelemetry(settings)

    plugins = []

    # SQLAlchemy
    alchemy_config = get_sqlalchemy_config(settings)
    from advanced_alchemy.extensions.litestar import SQLAlchemyPlugin
    plugins.append(SQLAlchemyPlugin(config=alchemy_config))

    # Structured logging
    plugins.append(StructlogPlugin())

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
            TaskController,
            PageController,
            HealthController,
            PrometheusController,
        ],
        plugins=plugins,
        template_config=TemplateConfig(
            directory="src/demo_app/templates",
            engine=JinjaTemplateEngine,
        ),
        static_files_config=[
            StaticFilesConfig(directories=["src/demo_app/static"], path="/static"),
        ],
        on_startup=[_log_startup],
        on_shutdown=[_log_shutdown],
        state=State({"version": settings.app_version}),
    )
