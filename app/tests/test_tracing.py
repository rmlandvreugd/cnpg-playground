"""App-factory-with-tracing regression test (no database required).

Guards the P0 fix: ``setup_opentelemetry`` previously imported a non-existent
``SERVICE_NAME_ATTRIBUTE`` from ``opentelemetry.sdk.resources``, so building the
app with ``DEMO_APP_TRACING_ENABLED=true`` crashed ``create_app`` at import time.
"""
from litestar import Litestar

from demo_app.config import AppSettings
from demo_app.main import create_app


def test_create_app_with_tracing_enabled() -> None:
    """The factory must build cleanly when tracing is on (no ImportError)."""
    app = create_app(AppSettings(tracing_enabled=True))
    assert isinstance(app, Litestar)
