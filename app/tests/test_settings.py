"""Settings / database-URL construction tests (no database required).

Covers the driver-normalisation and DATABASE_URL-vs-DB_* priority logic in
``AppSettings.database_url_async`` / ``database_url_sync``.
"""
from sqlalchemy.engine import make_url

from demo_app.config import AppSettings


def test_async_url_built_from_individual_fields() -> None:
    # database_url=None overrides any DEMO_APP_DATABASE_URL in the environment
    # so the per-field construction path is exercised deterministically.
    s = AppSettings(
        database_url=None,
        db_user="u", db_password="p", db_host="h", db_port=5555, db_name="d",
    )
    assert s.database_url_async == "postgresql+asyncpg://u:p@h:5555/d"


def test_sync_url_built_from_individual_fields() -> None:
    s = AppSettings(
        database_url=None,
        db_user="u", db_password="p", db_host="h", db_port=5555, db_name="d",
    )
    assert s.database_url_sync == "postgresql+psycopg://u:p@h:5555/d"


def test_database_url_overrides_individual_fields() -> None:
    s = AppSettings(
        database_url="postgresql://o:o@over:1/od", db_host="ignored"
    )
    # Plain postgresql:// gets the asyncpg driver for the async URL...
    assert s.database_url_async == "postgresql+asyncpg://o:o@over:1/od"
    # ...and psycopg for the sync (Alembic) URL.
    assert s.database_url_sync == "postgresql+psycopg://o:o@over:1/od"


def test_async_url_swaps_sync_driver_to_asyncpg() -> None:
    s = AppSettings(database_url="postgresql+psycopg://o:o@over:1/od")
    assert s.database_url_async == "postgresql+asyncpg://o:o@over:1/od"


def test_special_chars_in_credentials_are_escaped() -> None:
    # A generated password with @ : / ? must be percent-encoded so URL parsing
    # does not mistake it for host/port/path delimiters.
    s = AppSettings(
        database_url=None,
        db_user="ap@p", db_password="p@ss:w/rd?x",
        db_host="h", db_port=5432, db_name="d",
    )
    url = s.database_url_async
    assert "p@ss:w/rd?x" not in url  # raw special chars not present unescaped
    parsed = make_url(url)
    assert parsed.username == "ap@p"
    assert parsed.password == "p@ss:w/rd?x"
    assert parsed.host == "h"
    assert parsed.database == "d"
