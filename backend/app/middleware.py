import logging
import re
import secrets
import time
from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Request, Response

from app.context import request_id_var

logger = logging.getLogger("pruflo.request")

# Accept a caller's request ID only if it looks safe to echo and log.
_SAFE_ID = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")


def install_request_middleware(app: FastAPI) -> None:
    @app.middleware("http")
    async def request_context(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        incoming = request.headers.get("X-Request-ID", "")
        request_id = incoming if _SAFE_ID.match(incoming) else f"req_{secrets.token_hex(8)}"
        token = request_id_var.set(request_id)
        start = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            logger.exception("unhandled error", extra={"path": request.url.path})
            raise
        finally:
            request_id_var.reset(token)
        response.headers["X-Request-ID"] = request_id
        logger.info(
            "%s %s",
            request.method,
            request.url.path,  # path only: query strings may carry cursors or tokens
            extra={
                "path": request.url.path,
                "status_code": response.status_code,
                "ms": round((time.perf_counter() - start) * 1000, 1),
            },
        )
        return response
