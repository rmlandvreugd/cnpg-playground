"""Readiness-probe tests.

Guards the P1 fix: the readiness endpoint must return 503 when the database is
unreachable, so Kubernetes/Helm stop routing traffic to a broken pod (it
previously returned 200 with status=degraded). The failure path is exercised
deterministically by pointing the real app at a refused port — no live DB
needed.
"""
from litestar.testing import TestClient

from demo_app.config import AppSettings
from demo_app.main import create_app

# 127.0.0.1:1 refuses connections immediately, so asyncpg fails fast.
_UNREACHABLE_DB = "postgresql://app:x@127.0.0.1:1/demo"


def test_ready_returns_503_when_db_unavailable() -> None:
    settings = AppSettings(database_url=_UNREACHABLE_DB)
    with TestClient(app=create_app(settings)) as client:
        r = client.get("/health/ready")
        assert r.status_code == 503


def test_liveness_always_200_without_db() -> None:
    # Liveness must not depend on the database.
    settings = AppSettings(database_url=_UNREACHABLE_DB)
    with TestClient(app=create_app(settings)) as client:
        assert client.get("/health/").status_code == 200


def test_startup_always_200_without_db() -> None:
    settings = AppSettings(database_url=_UNREACHABLE_DB)
    with TestClient(app=create_app(settings)) as client:
        assert client.get("/health/startup").status_code == 200
