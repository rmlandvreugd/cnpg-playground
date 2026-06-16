"""CSRF protection tests for the server-rendered HTML form routes.

Guards the P3 fix: browser POST routes (create/update/delete via <form>) must
require a CSRF token, while the programmatic JSON API under /api/ stays exempt
so non-browser clients aren't broken. The DB is unreachable here on purpose —
the CSRF middleware runs before the handler, so the form routes never touch it.
"""
from litestar.testing import TestClient

from demo_app.config import AppSettings
from demo_app.main import create_app

_UNREACHABLE_DB = "postgresql://app:x@127.0.0.1:1/demo"


def _client() -> TestClient:
    return TestClient(app=create_app(AppSettings(database_url=_UNREACHABLE_DB)))


def test_form_page_renders_csrf_token() -> None:
    with _client() as client:
        body = client.get("/tasks/new").text
        assert '<input type="hidden"' in body
        assert "csrf" in body.lower()


def test_form_post_without_token_is_forbidden() -> None:
    with _client() as client:
        r = client.post("/tasks/create", data={"title": "x", "priority": "1"})
        assert r.status_code == 403


def test_json_api_is_exempt_from_csrf() -> None:
    # The /api/ route is excluded, so it is NOT blocked at the CSRF layer.
    # (It fails later for other reasons — unreachable DB — but never with 403.)
    with _client() as client:
        r = client.post("/api/v1/tasks", json={"title": "x", "priority": 1})
        assert r.status_code != 403
