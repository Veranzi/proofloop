"""Pruflo Cloud Run API (FastAPI).

/v1 routes verify the Firebase ID token (or an API key) and App Check token,
then apply case-level authorization. See Docs/backend_plan.md.
"""

from fastapi import FastAPI

from app.api.v1 import router as v1_router
from app.errors import install_error_handlers
from app.logging import configure_logging
from app.middleware import install_request_middleware


def create_app() -> FastAPI:
    configure_logging()
    app = FastAPI(title="Pruflo API", version="0.1.0")
    install_error_handlers(app)
    install_request_middleware(app)

    @app.get("/healthz", include_in_schema=False)
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(v1_router, prefix="/v1")
    return app


app = create_app()
