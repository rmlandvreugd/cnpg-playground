"""db_schema wiring tests (no database required).

Guards the P2 fix: DEMO_APP_DB_SCHEMA must actually pin the connection's
search_path, so tables land in the configured schema instead of always in
public.
"""
from demo_app.config import AppSettings
from demo_app.db.session import get_sqlalchemy_config


def test_engine_pins_search_path_to_configured_schema() -> None:
    cfg = get_sqlalchemy_config(AppSettings(db_schema="tenant_a"))
    search_path = cfg.engine_config.connect_args["server_settings"]["search_path"]
    assert search_path == "tenant_a"


def test_engine_defaults_search_path_to_public() -> None:
    cfg = get_sqlalchemy_config(AppSettings())
    search_path = cfg.engine_config.connect_args["server_settings"]["search_path"]
    assert search_path == "public"
