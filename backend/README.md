# PruFlo backend

The API and processing worker behind PruFlo. People upload evidence for a case, the worker reads the documents, rules flag discrepancies as findings, and a named reviewer approves or rejects each one. Everything runs on Google Cloud in `asia-southeast1` (Singapore).

The core rule: **code calculates, AI reads documents and drafts wording, and people decide.**

- [Build plan and progress](../Docs/backend_plan.md)
- [API contract, endpoints 1–33](../Docs/API_Contract.md) and [integrations contract, 34–50](../Docs/Integrations_API_Contract.md)
- Interactive API docs: `/docs` on a running API (`local`, `test` and `dev` only)

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Run locally](#run-locally)
- [Configuration](#configuration)
- [Authentication and access](#authentication-and-access)
- [Processing pipeline](#processing-pipeline)
- [Operator commands](#operator-commands)
- [Testing and checks](#testing-and-checks)
- [Database migrations](#database-migrations)
- [Deploying to Google Cloud](#deploying-to-google-cloud)
- [Security notes](#security-notes)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)

## Architecture

```
Flutter app ──HTTPS──▶ API (Cloud Run, FastAPI) ──▶ Cloud SQL (PostgreSQL)
     │                    │   └─ outbox ──▶ Pub/Sub ──push──▶ Worker (Cloud Run)
     └─ PUT (signed URL) ─┴──────────────▶ Cloud Storage ◀────────┘   │
                                                       Document AI ◀──┤ (OCR)
                                                       webhooks ◀─────┘ (signed POSTs)
```

| Piece | Code | What it does |
| --- | --- | --- |
| API | `app/main.py`, `app/api/v1/` | Endpoints 1–50: auth, permissions, cases, uploads, review, reports, admin, integrations |
| Worker | `app/worker/main.py` | Receives Pub/Sub pushes: processes evidence, renders reports, delivers webhooks |
| Pipeline | `app/pipeline/` | Text extraction (PDF, Word, Excel, CSV, TXT), OCR adapter, rule templates |
| Outbox | `app/services/outbox.py`, `app/worker/queue.py` | Events are written with the change that caused them, then published, so nothing is lost if a publish fails |

The API and worker are the same codebase in two Cloud Run services with separate service accounts. Locally, the API runs jobs itself right after responding, so no Pub/Sub emulator is needed.

## Requirements

- Python 3.12
- Docker (for the local PostgreSQL)
- For deployment: a GCP project with Cloud Run, Cloud SQL, Cloud Storage, Pub/Sub, Cloud Scheduler, Secret Manager and (optionally) Document AI enabled, and a Firebase project with Authentication

## Run locally

```bash
cd backend
cp .env.example .env                 # set PRUFLO_DB_PASSWORD (openssl rand -hex 16)
docker compose up -d postgres        # PostgreSQL on 127.0.0.1:5433
python3.12 -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
alembic upgrade head
python -m app.cli bootstrap --tenant "Acme Ltd" --admin-email you@example.com --admin-name "Your Name"
uvicorn app.main:app --reload --port 8000 --no-access-log
```

Check it's up at http://localhost:8000/healthz, and browse the endpoints at http://localhost:8000/docs.

Locally, sign in by sending `Authorization: Bearer dev:<any-id>:<invited email>` (only accepted when `PRUFLO_ENV=local`):

```bash
curl -H "Authorization: Bearer dev:me1:you@example.com" http://localhost:8000/v1/me
```

The Flutter app does this for you when it's built without Firebase settings. See [`frontend/README.md`](../frontend/README.md).

Uploaded files are stored under `backend/.local-storage/` and served through signed links from the API itself.

## Configuration

All settings are environment variables with the `PRUFLO_` prefix, read from `backend/.env` locally. On Cloud Run, set them on the service and mount secrets from Secret Manager.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PRUFLO_ENV` | `local` | `local`, `test`, `dev`, `staging` or `prod`. Development-only behaviour is refused outside `local`/`test` |
| `PRUFLO_DATABASE_URL` | – | Full SQLAlchemy URL (`postgresql+psycopg://...`). Use on Cloud Run, from Secret Manager |
| `PRUFLO_DB_PASSWORD` | – | Local database password; with `PRUFLO_DB_USER`/`HOST`/`PORT`/`NAME` it builds the URL when `PRUFLO_DATABASE_URL` is empty |
| `PRUFLO_GCP_PROJECT` | `pruflo-local` | GCP project for Storage, Pub/Sub and Document AI |
| `PRUFLO_FIREBASE_PROJECT` | `PRUFLO_GCP_PROJECT` | Firebase project whose ID tokens are accepted (`login-register-125ef` for pruflo.web.app) |
| `PRUFLO_FIREBASE_CHECK_REVOKED` | `true` | Also check that the session wasn't revoked. Needs the runtime identity to have Firebase Authentication admin access on the Firebase project; set `false` only locally |
| `PRUFLO_REGION` | `asia-southeast1` | Deployment region |
| `PRUFLO_STORAGE_BACKEND` | `local` | `gcs` on Cloud Run; `local` stores files on disk (local/test only) |
| `PRUFLO_EVIDENCE_BUCKET` | `pruflo-evidence-local` | Private bucket for evidence and reports |
| `PRUFLO_SIGNED_URL_MINUTES` | `10` | Lifetime of upload, view and download links |
| `PRUFLO_PUBLIC_BASE_URL` | `http://localhost:8000` | Base of local storage links (local only) |
| `PRUFLO_PUBLIC_APP_URL` | `https://pruflo.web.app` | The web app; push notifications link into it |
| `PRUFLO_QUEUE_BACKEND` | `inline` | `pubsub` on Cloud Run; `inline` runs jobs in the API process |
| `PRUFLO_PUBSUB_TOPIC` | `evidence-jobs` | Topic the outbox publishes to |
| `PRUFLO_WORKER_PUSH_AUDIENCE` | – | Worker URL; OIDC tokens must be issued for it |
| `PRUFLO_WORKER_INVOKER_SERVICE_ACCOUNTS` | `[]` | JSON list of service accounts allowed to call the worker (Pub/Sub push, Cloud Scheduler) |
| `PRUFLO_DOCUMENTAI_LOCATION` | – | Document AI location. A location outside the region sends documents abroad; get sign-off first |
| `PRUFLO_DOCUMENTAI_PROCESSOR_ID` | – | OCR processor. Without it, scans and images are marked `needs_review` |
| `PRUFLO_SECRETS_KEY` | – | Fernet key that encrypts webhook signing secrets. Required outside `local`/`test` |
| `PRUFLO_CORS_ORIGINS` | `["https://pruflo.web.app","https://pruflo.firebaseapp.com"]` | Browser origins allowed to call the API; any localhost port is also allowed in `local`/`test` |
| `PRUFLO_AUTH_DEV_MODE` | `false` | Accept `dev:` tokens. Ignored outside `local`/`test` |
| `PRUFLO_APP_CHECK_REQUIRED` | `true` | Require a Firebase App Check token from the app. Skipped in `local`/`test` |

Limits shared with the app: 25 MB per file, 200 PDF pages, 20 uploads in progress per case (`app/config.py`).

## Authentication and access

- **People** sign in with Firebase. The API verifies the ID token (with revocation) and the App Check token, then loads their membership. Access is invite-only: an admin invites an email address, and the person's Firebase account is linked on first sign-in with that verified address. Anyone else gets `403 not_invited`.
- **Other systems** use API keys (`Authorization: Bearer pf_live_...`), created by admins with scopes. Keys are stored as SHA-256 hashes and rate-limited to 600 requests a minute per instance.

| Action | investigator | reviewer | admin | viewer | API key |
| --- | --- | --- | --- | --- | --- |
| View cases, evidence and findings | ✓ | ✓ | ✓ | ✓ | `cases:read` |
| Create and edit cases, upload evidence | ✓ | | ✓ | | `cases:write`, `evidence:write` |
| Decide on findings | | ✓ | ✓ | | never |
| Reports and export | ✓ | ✓ | ✓ | | `reports:read`, `findings:read` |
| Admin and integrations | | | ✓ | | never |

People only see the cases they're members of (admins see all cases in their organisation). A case you can't see returns `404`.

## Processing pipeline

1. **Upload** (endpoints 7, 8): the client PUTs the file to a signed URL. On `complete`, the API checks the real file type from its content, the size and the PDF page count, computes the SHA-256, and writes a job plus an outbox event in one transaction.
2. **Extract** (worker): PDF text layer as lines with page positions, Word paragraphs and tables, Excel sheets with cell references, CSV and TXT. Pages without a text layer, and images, go to Document AI OCR if configured.
3. **Retry and failure**: jobs are claimed with a lease and are idempotent, so a redelivered message changes nothing. Unreadable files fail at once; temporary errors retry up to 5 times.
4. **Claims, grounding and rules** (plan Steps 9–11, not built yet): until then cases have no findings, and the review and export endpoints return empty lists.
5. **Review** (15): a reviewer approves, rejects (note required) or sets a finding back to pending. The case becomes `completed` when nothing is pending.
6. **Reports** (17–19): the worker renders a PDF from stored data only.
7. **Webhooks** (37–42): events are signed with HMAC-SHA256 and retried after 1 min, 5 min, 30 min, 2 h, 6 h and 12 h. An endpoint failing for 3 days is paused.
8. **Notifications** (51–53): the following create an in-app notification for the people concerned:
   - evidence finished processing (for the uploader);
   - a case assigned to someone;
   - a case ready for review (for reviewers and admins on the case);
   - a report ready (for whoever requested it);
   - an optional Monday summary.

   Each person switches kinds on or off in their profile (`PATCH /v1/me`). If push is on and they've registered a device (2), the worker sends it with Firebase Cloud Messaging and removes tokens FCM reports as dead. Notifications are kept 90 days.
9. **Profile photos** (54–56): uploaded like evidence, then re-encoded server-side as a JPEG of at most 512 px. This strips metadata such as GPS location.

## Operator commands

```bash
python -m app.cli bootstrap --tenant "Acme Ltd" --admin-email admin@acme.com --admin-name "Ada"
python -m app.cli invite --tenant ten_... --email someone@acme.com --role reviewer
python -m app.cli remove-user --email someone@acme.com   # keeps the audit trail, clears the email
python -m app.worker drain                               # process anything waiting, now
python -m app.worker weekly-summary                      # send this week's summaries now
```

## Testing and checks

```bash
docker compose up -d postgres      # tests use a separate pruflo_test database, recreated each run
ruff check . && ruff format --check .
mypy app
pytest
```

The same checks run in GitHub Actions (`.github/workflows/backend-ci.yml`) on pull requests that touch `backend/`.

## Database migrations

After changing `app/db/models.py`:

```bash
alembic revision --autogenerate -m "describe the change"
alembic check                       # models and migrations agree
```

Review the generated file before committing. Run migrations as a release step with the migration identity, never at app startup. `review_actions` and `audit_events` are append-only: a database trigger rejects updates and deletes.

## Deploying to Google Cloud

Plan Step 3 covers this; it hasn't been done yet. The pieces, all in `asia-southeast1`:

| Resource | Notes |
| --- | --- |
| Cloud SQL for PostgreSQL 16 | Private IP; separate migration and runtime users |
| Cloud Storage bucket | Uniform access, public access prevention; holds evidence and reports |
| Artifact Registry | `Dockerfile` (API) and `Dockerfile.worker` (worker, includes fonts for PDFs) |
| Cloud Run `pruflo-api` | `PRUFLO_STORAGE_BACKEND=gcs`, `PRUFLO_QUEUE_BACKEND=pubsub`, public, min instances 0 |
| Cloud Run `pruflo-worker` | No unauthenticated access, concurrency 1, same image settings plus the worker variables |
| Pub/Sub topic `evidence-jobs` | Push subscription to `https://<worker>/pubsub/push` with an OIDC token; retry backoff 10–600 s; dead-letter topic after 5 deliveries |
| Cloud Scheduler | OIDC calls to the worker: `POST /tasks/dispatch-outbox` and `POST /tasks/retry-webhooks` every minute; `POST /tasks/weekly-summary` on Mondays at 07:00 Asia/Singapore |
| Secret Manager | `PRUFLO_DATABASE_URL`, `PRUFLO_SECRETS_KEY` |
| Document AI | OCR processor, optional |

Give the API's service account Storage object admin on the bucket, Pub/Sub publisher, Cloud SQL client, Secret Manager accessor, and Service Account Token Creator on itself (for signed URLs). Give the worker the same (it also publishes follow-up events), plus Document AI API user and Firebase Cloud Messaging admin (`roles/firebasecloudmessaging.admin`, for push). If the Firebase project (`login-register-125ef`) isn't the GCP project the services run in, also grant both service accounts **Firebase Authentication Admin** on the Firebase project, for the revocation check and push. Don't download service-account keys.

## Security notes

- No secrets in the repository. Local credentials live in the git-ignored `backend/.env`; cloud secrets in Secret Manager.
- Signed URLs expire after 10 minutes and are never logged. uvicorn runs with `--no-access-log`; the app logs one JSON line per request without the query string.
- Logs never contain document text, tokens or keys.
- Webhook URLs must be HTTPS and resolve to public addresses, checked on save and before each send (SSRF protection). Redirects aren't followed.
- CSV exports neutralise cells that spreadsheet apps would run as formulas.
- Uploaded documents are untrusted: they're parsed as data and never executed. Macro-enabled Office files and encrypted PDFs are refused.

## Project layout

```
backend/
  app/
    api/v1/        routes, one module per area
    auth/          Firebase, App Check, API keys, permission table
    db/            models and Alembic migrations
    pipeline/      parsers, OCR adapter, rule templates
    reports/       PDF rendering
    services/      business logic shared by routes and the worker
    storage/       Cloud Storage and local storage, file-type detection
    worker/        worker service, job runner, outbox dispatcher
    cli.py         operator commands
  tests/           pytest suite (runs against PostgreSQL)
  Dockerfile       API image
  Dockerfile.worker
  docker-compose.yml
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `docker compose up` says `PRUFLO_DB_PASSWORD` is missing | Copy `.env.example` to `.env` and set it |
| `password authentication failed` | The password in `.env` doesn't match the database volume. Set it with `docker compose exec postgres psql -U pruflo -c "ALTER USER pruflo WITH PASSWORD '...'"` |
| `403 not_invited` | Invite the email with `python -m app.cli invite` (or `bootstrap` for a new organisation) |
| Files stay `queued` locally | Run `python -m app.worker drain`; check `PRUFLO_QUEUE_BACKEND=inline` |
| Scans end as `needs_review` (`ocr_not_configured`) | Expected without Document AI; set the two `PRUFLO_DOCUMENTAI_*` variables |
| The browser reports a CORS error | Add the app's origin to `PRUFLO_CORS_ORIGINS` |
