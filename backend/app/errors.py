"""One error envelope for every failure:

{"error": {"code": "...", "message": "...", "field": null, "request_id": "req_..."}}
"""

from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.context import request_id_var


class ApiError(Exception):
    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        field: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.field = field
        self.headers = headers


def bad_request(
    message: str, field: str | None = None, code: str = "validation_failed"
) -> ApiError:
    return ApiError(400, code, message, field)


def unauthorized(message: str = "Authentication required.") -> ApiError:
    return ApiError(401, "unauthenticated", message, headers={"WWW-Authenticate": "Bearer"})


def forbidden(message: str = "You don't have permission to do this.") -> ApiError:
    return ApiError(403, "forbidden", message)


def not_found(what: str = "Resource") -> ApiError:
    # Also used when the caller can't see the resource, so its existence isn't leaked.
    return ApiError(404, "not_found", f"{what} not found.")


def conflict(message: str) -> ApiError:
    return ApiError(409, "conflict", message)


def _envelope(code: str, message: str, field: str | None = None) -> dict[str, Any]:
    return {
        "error": {
            "code": code,
            "message": message,
            "field": field,
            "request_id": request_id_var.get(),
        }
    }


_STATUS_CODES = {
    400: "bad_request",
    401: "unauthenticated",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    429: "rate_limited",
}


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(
            _envelope(exc.code, exc.message, exc.field),
            status_code=exc.status_code,
            headers=exc.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        first = exc.errors()[0] if exc.errors() else {}
        loc = [str(p) for p in first.get("loc", []) if p not in ("body", "query", "path")]
        return JSONResponse(
            _envelope(
                "validation_failed", first.get("msg", "Invalid request."), ".".join(loc) or None
            ),
            status_code=400,
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _STATUS_CODES.get(exc.status_code, "error")
        return JSONResponse(
            _envelope(code, str(exc.detail)), status_code=exc.status_code, headers=exc.headers
        )

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        # Logged by the middleware; never echo internals to the client.
        return JSONResponse(_envelope("internal", "Something went wrong."), status_code=500)
