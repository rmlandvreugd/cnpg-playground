"""DB-backed CRUD + persistence tests (skipped when no database is reachable).

Every test depends on the ``db_required`` fixture, which skips the test if the
configured Postgres is down. Created rows are cleaned up via the API.
"""
import pytest
from litestar.testing import TestClient

pytestmark = pytest.mark.usefixtures("db_required")


def _delete_by_title(client: TestClient, *titles: str) -> None:
    for task in client.get("/api/v1/tasks").json():
        if task["title"] in titles:
            client.delete(f"/api/v1/tasks/{task['id']}")


def _find_by_title(client: TestClient, title: str) -> dict:
    return next(t for t in client.get("/api/v1/tasks").json() if t["title"] == title)


def test_json_create_returns_read_dto(client: TestClient) -> None:
    title = "crud-json-create"
    try:
        r = client.post("/api/v1/tasks", json={"title": title, "priority": 3})
        assert r.status_code == 201
        body = r.json()
        assert body["title"] == title and body["priority"] == 3
        assert "id" in body and "created_at" in body  # read DTO shape
    finally:
        _delete_by_title(client, title)


def test_json_id_is_excluded_from_create(client: TestClient) -> None:
    """A client-supplied ``id`` must not be honored (mass-assignment protection)."""
    title = "crud-json-massassign"
    try:
        r = client.post("/api/v1/tasks", json={"title": title, "id": 999999})
        assert r.status_code == 201
        assert r.json()["id"] != 999999
    finally:
        _delete_by_title(client, title)


def test_json_partial_update_changes_only_submitted_field(client: TestClient) -> None:
    title = "crud-json-partial"
    try:
        created = client.post(
            "/api/v1/tasks", json={"title": title, "priority": 2}
        ).json()
        r = client.put(f"/api/v1/tasks/{created['id']}", json={"done": True})
        assert r.status_code == 200
        updated = r.json()
        assert updated["done"] is True
        assert updated["title"] == title and updated["priority"] == 2  # untouched
    finally:
        _delete_by_title(client, title)


def test_form_create_normalizes_blanks_and_done(client: TestClient) -> None:
    """Blank optionals -> NULL; done='false' stored as not-done (truthiness fix)."""
    title = "crud-form-blanks"
    try:
        r = client.post(
            "/tasks/create",
            data={"title": title, "done": "false", "assignee": "", "priority": ""},
            follow_redirects=False,
        )
        assert r.status_code in (302, 303)
        task = _find_by_title(client, title)
        assert task["done"] is False
        assert task["assignee"] is None and task["priority"] is None
    finally:
        _delete_by_title(client, title)


def test_form_update_can_clear_optional_fields(client: TestClient) -> None:
    """The form path can clear a field to NULL (not possible with a partial DTO)."""
    title = "crud-form-clear"
    try:
        client.post(
            "/tasks/create",
            data={"title": title, "done": "true", "assignee": "bob", "priority": "4"},
            follow_redirects=False,
        )
        tid = _find_by_title(client, title)["id"]
        r = client.post(
            f"/tasks/{tid}/update",
            data={"title": title, "done": "false", "assignee": "", "priority": ""},
            follow_redirects=False,
        )
        assert r.status_code in (302, 303)
        task = client.get(f"/api/v1/tasks/{tid}").json()
        assert task["assignee"] is None
        assert task["priority"] is None
        assert task["done"] is False
    finally:
        _delete_by_title(client, title)
