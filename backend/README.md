# Pruflo backend

Python services for Pruflo on Google Cloud (asia-southeast1, Singapore):

- **Cloud Run API** (FastAPI) – token validation, case-level authorization, signed URLs, Cloud SQL access.
- **Cloud Run worker** – Pub/Sub-driven evidence pipeline: text extraction, OCR, Gemini extraction, grounding, findings.
- **Report generation** – HTML template to PDF.

The build plan is in [`Docs/backend_plan.md`](../Docs/backend_plan.md).

## Run locally

Needs Python 3.12 and Docker.

```bash
cd backend
docker compose up -d                 # Postgres, Pub/Sub emulator, fake Cloud Storage
python3.12 -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
cp .env.example .env
alembic upgrade head                 # create the tables
uvicorn app.main:app --reload --port 8000
```

Then open http://127.0.0.1:8000/healthz or http://127.0.0.1:8000/docs.
The Flutter app calls `http://localhost:8000` by default.

## Checks

```bash
ruff check . && ruff format --check .
mypy app
pytest                               # needs the Postgres container running
```

Tests use a separate `pruflo_test` database that is recreated on each run.

## Layout

| Path | What |
| --- | --- |
| `app/enums.py` | Wire values shared with the frontend (case status, review decision, roles...) |
| `app/errors.py` | The `{"error": {...}}` envelope used by every endpoint |
| `app/db/models.py` | Tables; `app/db/migrations/` holds the Alembic migrations |
| `app/api/v1/` | Routes; endpoint numbers match `frontend/lib/core/api_endpoints.dart` |

## Migrations

After changing `app/db/models.py`:

```bash
alembic revision --autogenerate -m "describe the change"
```

Review the generated file before committing. Migrations run as a release step, never at app startup.
