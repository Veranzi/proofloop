"""Cursor pagination: lists return ``{"items": [...], "next_cursor": null}``.

The cursor is an opaque string; clients never parse it.
"""

import base64
import json
from datetime import datetime
from typing import Any

from pydantic import BaseModel

from app.errors import bad_request

DEFAULT_LIMIT = 50
MAX_LIMIT = 200


class Page[T](BaseModel):
    items: list[T]
    next_cursor: str | None = None


def encode_cursor(created_at: datetime, row_id: str) -> str:
    raw = json.dumps({"t": created_at.isoformat(), "id": row_id}).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, str]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        data: dict[str, Any] = json.loads(base64.urlsafe_b64decode(padded))
        return datetime.fromisoformat(data["t"]), str(data["id"])
    except (ValueError, KeyError, TypeError) as exc:
        raise bad_request("Invalid cursor.", field="cursor") from exc


def clamp_limit(limit: int | None) -> int:
    if limit is None:
        return DEFAULT_LIMIT
    return max(1, min(limit, MAX_LIMIT))
