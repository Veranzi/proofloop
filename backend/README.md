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
cp .env.example .env                 # then set PRUFLO_DB_PASSWORD (openssl rand -hex 16)
alembic upgrade head                 # create the tables
uvicorn app.main:app --reload --port 8000 --no-access-log
```

Then open http://127.0.0.1:8000/healthz or http://127.0.0.1:8000/docs.
The Flutter app calls `http://localhost:8000` by default.

## Signing in locally

Create an organisation and its first admin:

```bash
python -m app.cli bootstrap --tenant "Acme Ltd" --admin-email you@example.com --admin-name "Your Name"
```

Invite more people, or remove someone's access:

```bash
python -m app.cli invite --tenant ten_... --email someone@example.com --role admin
python -m app.cli remove-user --email someone@example.com
```

`remove-user` keeps the user row (with the email cleared) because the append-only audit trail refers to it.

With `PRUFLO_AUTH_DEV_MODE=true` (local and test only), send `Authorization: Bearer dev:<any-uid>:<email>`
instead of a Firebase token. The first call links that UID to the invited email.

```bash
curl -H "Authorization: Bearer dev:me1:you@example.com" http://localhost:8000/v1/me
```

Everywhere else the API only accepts Firebase ID tokens (plus App Check) or `pf_live_` API keys.
Users who haven't been invited get `403 not_invited`.

## Processing uploads (worker)

Locally (`PRUFLO_QUEUE_BACKEND=inline`) the API processes each upload itself right after
responding, so files move from `queued` to `processed` (or `needs_review`) within seconds.
To process anything still waiting, for example after a restart:

```bash
python -m app.worker drain
```

On Cloud Run the API only writes the job; the separate worker service (`Dockerfile.worker`,
`app/worker/main.py`) receives it from Pub/Sub:

| Piece | Setting |
| --- | --- |
| API | `PRUFLO_QUEUE_BACKEND=pubsub`, `PRUFLO_PUBSUB_TOPIC=evidence-jobs` |
| Push subscription | to `https://<worker>/pubsub/push` with an OIDC token; retry backoff 10s–600s; dead-letter topic after 5 deliveries |
| Cloud Scheduler | every minute, `POST https://<worker>/tasks/dispatch-outbox` with an OIDC token, to publish anything the API couldn't |
| Worker | `PRUFLO_WORKER_PUSH_AUDIENCE=https://<worker>`, `PRUFLO_WORKER_INVOKER_SERVICE_ACCOUNTS=["<push SA>","<scheduler SA>"]`, concurrency 1 |

Text extraction uses the file's own text (PDF text layer, Word, Excel, CSV, TXT). Images and
scanned PDF pages need OCR: set `PRUFLO_DOCUMENTAI_LOCATION` and `PRUFLO_DOCUMENTAI_PROCESSOR_ID`.
Without them those files are marked `needs_review` with `error_class: ocr_not_configured`.

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
