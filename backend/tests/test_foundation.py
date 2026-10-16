from datetime import UTC, datetime

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient
from pydantic import BaseModel

from app.errors import ApiError, bad_request
from app.ids import new_id
from app.main import create_app
from app.pagination import clamp_limit, decode_cursor, encode_cursor


class _Body(BaseModel):
    name: str


def _client() -> TestClient:
    app = create_app()
    probe = APIRouter()

    @probe.get("/probe/api-error")
    def api_error() -> None:
        raise bad_request("url must use https", field="url")

    @probe.post("/probe/body")
    def body(payload: _Body) -> dict[str, str]:
        return {"name": payload.name}

    @probe.get("/probe/crash")
    def crash() -> None:
        raise RuntimeError("secret internals")

    app.include_router(probe)
    return TestClient(app, raise_server_exceptions=False)


def test_healthz() -> None:
    res = _client().get("/healthz")
    assert res.status_code == 200
    assert res.json() == {"status": "ok"}
    assert res.headers["X-Request-ID"].startswith("req_")


def test_request_id_is_echoed_when_safe() -> None:
    client = _client()
    assert (
        client.get("/healthz", headers={"X-Request-ID": "abc-123"}).headers["X-Request-ID"]
        == "abc-123"
    )
    unsafe = client.get("/healthz", headers={"X-Request-ID": "bad id\nwith newline"})
    assert unsafe.headers["X-Request-ID"].startswith("req_")


def test_api_error_uses_envelope() -> None:
    res = _client().get("/probe/api-error", headers={"X-Request-ID": "req_t1"})
    assert res.status_code == 400
    assert res.json() == {
        "error": {
            "code": "validation_failed",
            "message": "url must use https",
            "field": "url",
            "request_id": "req_t1",
        }
    }


def test_validation_error_uses_envelope() -> None:
    res = _client().post("/probe/body", json={})
    assert res.status_code == 400
    err = res.json()["error"]
    assert err["code"] == "validation_failed"
    assert err["field"] == "name"


def test_not_found_and_crash_use_envelope() -> None:
    client = _client()
    assert client.get("/nope").json()["error"]["code"] == "not_found"
    crash = client.get("/probe/crash")
    assert crash.status_code == 500
    assert crash.json()["error"]["message"] == "Something went wrong."
    assert "secret" not in crash.text


def test_cursor_round_trip_and_rejects_garbage() -> None:
    at = datetime(2026, 10, 16, 9, 30, tzinfo=UTC)
    assert decode_cursor(encode_cursor(at, "case_1")) == (at, "case_1")
    with pytest.raises(ApiError):
        decode_cursor("not-a-cursor")


def test_limits_and_ids() -> None:
    assert clamp_limit(None) == 50
    assert clamp_limit(0) == 1
    assert clamp_limit(10_000) == 200
    a, b = new_id("evd"), new_id("evd")
    assert a.startswith("evd_") and a != b


def test_request_log_carries_request_id(caplog: pytest.LogCaptureFixture) -> None:
    import logging

    client = _client()  # create_app() replaces the root handlers, so re-attach caplog's
    logging.getLogger().addHandler(caplog.handler)
    with caplog.at_level("INFO", logger="pruflo.request"):
        client.get("/healthz?sig=secret", headers={"X-Request-ID": "req_log1"})
    from app.logging import JsonFormatter

    record = next(r for r in caplog.records if r.name == "pruflo.request")
    line = JsonFormatter().format(record)
    assert '"request_id": "req_log1"' in line
    assert "secret" not in line
