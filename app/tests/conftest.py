"""Shared pytest fixtures.

The validation tests are DB-free: ``TaskService._validate`` raises before any
query, and Litestar opens the DB connection lazily (on first use), so a request
that 400s never touches Postgres. CRUD/persistence tests require a live DB and
skip cleanly when one is not reachable.
"""
import re
from collections.abc import Callable

import httpx
import pytest
from litestar.testing import TestClient

from demo_app.config import AppSettings
from demo_app.main import create_app

_CSRF_FIELD = re.compile(r'name="_csrf_token" value="([^"]+)"')


@pytest.fixture
def client() -> TestClient:
    """A TestClient over a freshly-built app (settings read from env)."""
    with TestClient(app=create_app(AppSettings())) as test_client:
        yield test_client


@pytest.fixture
def form_post(client: TestClient) -> Callable[..., httpx.Response]:
    """POST to an HTML form route with a valid CSRF token attached.

    Mirrors a real browser submit: the token is read from a rendered form page
    (which also seeds the matching cookie on the shared client) and sent back as
    the hidden ``_csrf_token`` field. Form routes are CSRF-protected, so plain
    ``client.post`` to them now 403s — tests that exercise the form path go
    through this helper instead.
    """
    token = _CSRF_FIELD.search(client.get("/tasks/new").text).group(1)

    def _post(path: str, data: dict, **kwargs: object) -> httpx.Response:
        return client.post(path, data={**data, "_csrf_token": token}, **kwargs)

    return _post


@pytest.fixture
def db_required(client: TestClient) -> None:
    """Skip the test unless the configured database is reachable.

    Uses a trivial DB-touching request as the probe; a 5xx means the database
    is down, so dependent tests are skipped rather than failed.
    """
    if client.get("/api/v1/tasks").status_code >= 500:
        pytest.skip("database not reachable; skipping DB-backed test")
