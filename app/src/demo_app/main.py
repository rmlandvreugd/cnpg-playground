import logging

import structlog
from litestar import Litestar
from litestar.contrib.jinja import JinjaTemplateEngine
from litestar.datastructures import State
from litestar.logging.config import StructLoggingConfig
from litestar.plugins import PluginProtocol
from litestar.plugins.prometheus import PrometheusConfig, PrometheusController
from litestar.plugins.structlog import StructlogConfig, StructlogPlugin
from litestar.static_files.config import StaticFilesConfig
from litestar.template.config import TemplateConfig

from demo_app.config import AppSettings
from demo_app.controllers.health import HealthController
from demo_app.controllers.pages import PageController
from demo_app.controllers.tasks import TaskController
from demo_app.db.session import get_sqlalchemy_config

logger = logging.getLogger(__name__)


def setup_opentelemetry(settings: AppSettings) -> None:
    """Configure OTel auto-instrumentation for v2.

    Called before app creation so that instrumentors can wrap
    libraries at import time.
    """
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create({
        "service.name": "demo-app",
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

    # Note: HTTP/ASGI request spans are emitted by Litestar's own
    # OpenTelemetryPlugin (wired in create_app), not a global instrumentor —
    # opentelemetry.instrumentation.asgi exposes only OpenTelemetryMiddleware.
    from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

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

    plugins: list[PluginProtocol] = []

    # SQLAlchemy
    alchemy_config = get_sqlalchemy_config(settings)
    from advanced_alchemy.extensions.litestar import SQLAlchemyPlugin
    plugins.append(SQLAlchemyPlugin(config=alchemy_config))

    # Structured logging — honor DEMO_APP_LOG_LEVEL (e.g. DEBUG)
    log_level = logging.getLevelName(settings.log_level)
    plugins.append(
        StructlogPlugin(
            config=StructlogConfig(
                structlog_logging_config=StructLoggingConfig(
                    wrapper_class=structlog.make_filtering_bound_logger(log_level),
                ),
            ),
        )
    )

    # Prometheus — register the middleware (which records request metrics) and
    # the /metrics controller only when metrics are enabled.
    route_handlers = [TaskController, PageController, HealthController]
    middleware = []
    if settings.metrics_enabled:
        prometheus_config = PrometheusConfig(
            app_name="demo_app",
            labels={"version": settings.app_version},
        )
        middleware.append(prometheus_config.middleware)
        route_handlers.append(PrometheusController)

    # OpenTelemetry plugin (adds Litestar-specific spans on top of auto-instrumentation)
    if settings.tracing_enabled:
        from litestar.plugins.opentelemetry import (
            OpenTelemetryConfig,
            OpenTelemetryPlugin,
        )
        plugins.append(OpenTelemetryPlugin(OpenTelemetryConfig()))

    return Litestar(
        debug=settings.debug,
        route_handlers=route_handlers,
        middleware=middleware,
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
