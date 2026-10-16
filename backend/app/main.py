"""Pruflo Cloud Run API (FastAPI).

/v1 routes will verify the Firebase ID token and App Check token, then apply
case-level authorization. See Docs/ for the technical architecture.
"""

from fastapi import FastAPI

app = FastAPI(title="Pruflo API", version="0.1.0")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
