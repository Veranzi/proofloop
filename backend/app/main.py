"""Pruflo Cloud Run API (FastAPI).

/v1 routes verify the Firebase ID token (or an API key) and App Check token,
then apply case-level authorization. See Docs/backend_plan.md.
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1 import local_objects
from app.api.v1 import router as v1_router
from app.config import get_settings
from app.errors import install_error_handlers
from app.logging import configure_logging
from app.middleware import install_request_middleware


def install_cors(app: FastAPI) -> None:
    settings = get_settings()
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        # `flutter run -d chrome` picks a random localhost port.
        allow_origin_regex=(
            r"http://(localhost|127\.0\.0\.1)(:\d+)?" if settings.env in ("local", "test") else None
        ),
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=[
            "Authorization",
            "Content-Type",
            "X-Firebase-AppCheck",
            "X-Pruflo-Tenant",
            "X-Request-ID",
        ],
        expose_headers=["X-Request-ID", "Retry-After"],
        max_age=600,
    )


def create_app() -> FastAPI:
    configure_logging()
    # Interactive docs only where developers work; the contracts are in Docs/.
    show_docs = get_settings().env in ("local", "test", "dev")
    app = FastAPI(
        title="Pruflo API",
        version="0.1.0",
        docs_url="/docs" if show_docs else None,
        redoc_url=None,
        openapi_url="/openapi.json" if show_docs else None,
    )
    install_error_handlers(app)
    install_request_middleware(app)
    install_cors(app)

    @app.get("/healthz", include_in_schema=False)
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(v1_router, prefix="/v1")
    if get_settings().env in ("local", "test"):
        # Stands in for signed Cloud Storage URLs; never mounted in the cloud.
        app.include_router(local_objects.router, prefix="/v1")
    return app


app = create_app()
