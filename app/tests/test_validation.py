"""Request-boundary validation tests (no database required).

These exercise the P1 fix: both controllers route writes through ``TaskService``,
so invalid input becomes a structured 4xx *before* any DB I/O, and
server-managed fields cannot be mass-assigned.
"""
from litestar.testing import TestClient

# --- JSON API (controllers/tasks.py) ---

def test_json_create_empty_title_returns_400(client: TestClient) -> None:
    r = client.post("/api/v1/tasks", json={"title": ""})
    assert r.status_code == 400
    assert r.json()["extra"]["title"]


def test_json_create_bad_priority_type_returns_400(client: TestClient) -> None:
    # DTO type-coercion rejects a non-int priority.
    r = client.post("/api/v1/tasks", json={"title": "x", "priority": "abc"})
    assert r.status_code == 400


def test_json_create_priority_out_of_range_returns_400(client: TestClient) -> None:
    r = client.post("/api/v1/tasks", json={"title": "x", "priority": 99})
    assert r.status_code == 400
    assert r.json()["extra"]["priority"]


# --- HTML form path (controllers/pages.py) ---

def test_form_create_empty_title_returns_400(form_post) -> None:
    r = form_post(
        "/tasks/create",
        data={"title": "", "done": "false", "assignee": "", "priority": ""},
        follow_redirects=False,
    )
    assert r.status_code == 400


def test_form_create_priority_out_of_range_returns_400(form_post) -> None:
    r = form_post(
        "/tasks/create",
        data={"title": "x", "done": "false", "assignee": "", "priority": "99"},
        follow_redirects=False,
    )
    assert r.status_code == 400
