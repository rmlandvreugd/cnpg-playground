#!/usr/bin/env bash
# dev.sh — Local development script for the Litestar Task Tracker app
#
# Usage:
#   ./scripts/dev.sh up        — Start PostgreSQL, PgBouncer, pgAdmin
#   ./scripts/dev.sh migrate   — Run Alembic migrations
#   ./scripts/dev.sh seed      — Seed the database with sample data
#   ./scripts/dev.sh run       — Start the Litestar dev server
#   ./scripts/dev.sh all       — up + migrate + seed + run (full dev setup)
#   ./scripts/dev.sh down      — Stop all services
#   ./scripts/dev.sh reset     — down + remove volumes (fresh start)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Default database URL (via PgBouncer) — used by the app at runtime
DEFAULT_DATABASE_URL="postgresql://app:app_password@localhost:16432/demo"

# Direct Postgres URL (bypasses PgBouncer) — used for migrations.
# PgBouncer rejects the psycopg3 SCRAM negotiation with "wrong password type",
# and DDL/migrations should not run through a transaction pooler anyway.
DEFAULT_DIRECT_DATABASE_URL="postgresql://app:app_password@localhost:15432/demo"

# App spec for the litestar CLI. Required for the advanced-alchemy `database`
# command group to register — the CLI does not read [tool.litestar] from
# pyproject.toml for app discovery.
export LITESTAR_APP="demo_app.main:create_app"

cmd_up() {
    info "Starting PostgreSQL, PgBouncer, and pgAdmin..."
    docker compose -f "$APP_DIR/compose.yaml" up -d

    info "Waiting for PgBouncer to be healthy..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if docker compose -f "$APP_DIR/compose.yaml" exec -T pgbouncer pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
            ok "PgBouncer is healthy"
            break
        fi
        retries=$((retries - 1))
        sleep 1
    done

    if [ $retries -eq 0 ]; then
        error "PgBouncer did not become healthy in time"
        return 1
    fi

    # Create the app user and readonly role if they don't exist
    info "Creating app user and readonly role..."
    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "DO \$\$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') THEN
                CREATE ROLE app LOGIN PASSWORD 'app_password';
            END IF;
        END \$\$;" 2>/dev/null || true

    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "DO \$\$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'readonly') THEN
                CREATE ROLE readonly LOGIN PASSWORD 'readonly_password';
            END IF;
        END \$\$;" 2>/dev/null || true

    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "GRANT ALL PRIVILEGES ON DATABASE demo TO app;" 2>/dev/null || true

    # Postgres 15+ no longer grants CREATE on schema public to non-owners, so
    # the app role needs explicit schema privileges to run migrations (DDL).
    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "GRANT ALL ON SCHEMA public TO app;" 2>/dev/null || true

    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "GRANT USAGE ON SCHEMA public TO readonly;" 2>/dev/null || true

    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;" 2>/dev/null || true

    # Ensure readonly automatically gets SELECT on tables the app creates later.
    docker compose -f "$APP_DIR/compose.yaml" exec -T postgres psql -U postgres -d demo -c \
        "ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA public GRANT SELECT ON TABLES TO readonly;" 2>/dev/null || true

    ok "Database services are ready"
    echo ""
    echo "  PostgreSQL:  localhost:15432 (direct)"
    echo "  PgBouncer:   localhost:16432 (pooled — use this for the app)"
    echo "  pgAdmin:     http://localhost:5050 (admin@example.com / pgadmin_secret)"
    echo ""
    echo "  Connection string for the app:"
    echo "    export DEMO_APP_DATABASE_URL=\"postgresql://app:app_password@localhost:16432/demo\""
}

cmd_migrate() {
    info "Running Alembic migrations (direct to Postgres, bypassing PgBouncer)..."
    cd "$APP_DIR"
    # Migrations are DDL admin work — run them directly against Postgres rather
    # than through the connection pooler.
    export DEMO_APP_DATABASE_URL="${DEMO_APP_MIGRATE_DATABASE_URL:-$DEFAULT_DIRECT_DATABASE_URL}"
    info "DATABASE_URL: $DEMO_APP_DATABASE_URL"
    uv run litestar database upgrade --no-prompt
    ok "Migrations complete"
}

cmd_seed() {
    info "Seeding database with sample data..."
    cd "$APP_DIR"
    export DEMO_APP_DATABASE_URL="${DEMO_APP_DATABASE_URL:-$DEFAULT_DATABASE_URL}"
    uv run python -m demo_app.seed
    ok "Seeding complete"
}

cmd_run() {
    info "Starting Litestar dev server..."
    cd "$APP_DIR"
    export DEMO_APP_DATABASE_URL="${DEMO_APP_DATABASE_URL:-$DEFAULT_DATABASE_URL}"
    export DEMO_APP_DEBUG=true
    export DEMO_APP_LOG_LEVEL=DEBUG
    export DEMO_APP_TRACING_ENABLED=false
    info "DATABASE_URL: $DEMO_APP_DATABASE_URL"
    uv run uvicorn demo_app.main:create_app --factory --host 0.0.0.0 --port 8008 --reload
}

cmd_down() {
    info "Stopping all services..."
    docker compose -f "$APP_DIR/compose.yaml" down
    ok "Services stopped"
}

cmd_reset() {
    warn "This will remove all data. Continue? [y/N]"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        docker compose -f "$APP_DIR/compose.yaml" down -v
        ok "All data removed"
    else
        info "Reset cancelled"
    fi
}

cmd_status() {
    docker compose -f "$APP_DIR/compose.yaml" ps
}

# Main
case "${1:-help}" in
    up)      cmd_up ;;
    migrate) cmd_migrate ;;
    seed)    cmd_seed ;;
    run)     cmd_run ;;
    all)
        cmd_up
        cmd_migrate
        cmd_seed
        cmd_run
        ;;
    down)    cmd_down ;;
    reset)   cmd_reset ;;
    status)  cmd_status ;;
    help|*)
        echo "Usage: $0 {up|migrate|seed|run|all|down|reset|status}"
        echo ""
        echo "Commands:"
        echo "  up        Start PostgreSQL, PgBouncer, pgAdmin"
        echo "  migrate   Run Alembic migrations"
        echo "  seed      Seed database with sample data"
        echo "  run       Start Litestar dev server with hot-reload"
        echo "  all       up + migrate + seed + run"
        echo "  down      Stop all services"
        echo "  reset     Stop services and remove all data"
        echo "  status    Show service status"
        echo ""
        echo "Environment variables:"
        echo "  DEMO_APP_DATABASE_URL  Override the database URL"
        echo "  DEMO_APP_DEBUG         Enable debug mode (default: true for dev.sh)"
        echo "  DEMO_APP_LOG_LEVEL     Log level (default: DEBUG for dev.sh)"
        ;;
esac