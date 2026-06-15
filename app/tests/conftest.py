"""Shared pytest fixtures.

The validation tests are DB-free: ``TaskService._validate`` raises before any
query, and Litestar opens the DB connection lazily (on first use), so a request
that 400s never touches Postgres. CRUD/persistence tests require a live DB and
skip cleanly when one is not reachable.
"""
import pytest
from litestar.testing import TestClient

from demo_app.config import AppSettings
from demo_app.main import create_app


@pytest.fixture
def client() -> TestClient:
    """A TestClient over a freshly-built app (settings read from env)."""
    with TestClient(app=create_app(AppSettings())) as test_client:
        yield test_client


@pytest.fixture
def db_required(client: TestClient) -> None:
    """Skip the test unless the configured database is reachable.

    Uses a trivial DB-touching request as the probe; a 5xx means the database
    is down, so dependent tests are skipped rather than failed.
    """
    if client.get("/api/v1/tasks").status_code >= 500:
        pytest.skip("database not reachable; skipping DB-backed test")
