# PruFlo

PruFlo is an evidence review and reconciliation system for the Southeast Asian market (Singapore, Malaysia and Indonesia). Teams upload a case's documents, such as purchase orders, delivery notes and invoices. PruFlo reads them, rules flag discrepancies such as a 20-unit shortfall, and a named reviewer approves or rejects each finding with the source text in front of them. Every step is kept in an audit trail.

> **Core rule:** code calculates and validates; AI only extracts or explains; an authorised person makes every decision.

| | |
| --- | --- |
| Web app | https://pruflo.web.app (Firebase Hosting) |
| Backend | FastAPI on Cloud Run, `asia-southeast1` (Singapore) |
| Status | Plan Steps 0–8 and the API for 13–16 are built; GCP deployment (Step 3) and the AI extraction and rule engine (Steps 9–12) are next. See [progress](Docs/backend_plan.md#progress) |

## Repository

| Folder | Contents | Read |
| --- | --- | --- |
| [`frontend/`](frontend/) | Flutter app for web, Android and iOS | [frontend/README.md](frontend/README.md) |
| [`backend/`](backend/) | Python API, processing worker and report generation | [backend/README.md](backend/README.md) |
| [`Docs/`](Docs/) | Architecture, plan and API contracts | below |
| `.github/workflows/` | Backend checks; Firebase Hosting deploys and PR previews | |

### Documentation

- [Backend implementation plan and progress](Docs/backend_plan.md)
- [API contract: endpoints 1–33](Docs/API_Contract.md) (profile, cases, evidence, review, reports, admin)
- [Integrations contract: endpoints 34–50](Docs/Integrations_API_Contract.md) (API keys, webhooks, document sources, rules, providers, export)
- [Technical architecture report](Docs/Pruflo_GCP_Technical_Architecture_Report.pdf)

## How it fits together

```
Flutter app (Firebase Auth) ──▶ API (Cloud Run) ──▶ PostgreSQL (Cloud SQL)
        │                          │  outbox ──▶ Pub/Sub ──▶ Worker (Cloud Run)
        └──── signed upload ──────▶ Cloud Storage ◀───────────┘  ├─ text extraction / OCR
                                                                   ├─ PDF reports
                                                                   └─ signed webhooks
```

## Quick start (local)

Requirements: Python 3.12, Docker, and Flutter (stable channel).

```bash
# 1. Backend
cd backend
cp .env.example .env                  # set PRUFLO_DB_PASSWORD: openssl rand -hex 16
docker compose up -d postgres
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
alembic upgrade head
python -m app.cli bootstrap --tenant "Demo Ltd" --admin-email you@example.com --admin-name "Your Name"
uvicorn app.main:app --reload --port 8000 --no-access-log

# 2. Frontend, in another terminal
cd frontend
flutter pub get
flutter run -d chrome
```

Sign in with the email you bootstrapped. Without Firebase settings, the app uses the backend's development sign-in, which only works locally. The two READMEs cover configuration, Firebase sign-in, tests and deployment.

## Branches and pull requests

| Branch | Purpose |
| --- | --- |
| `main` | Reviewed, releasable code. Merging deploys the web app to Firebase Hosting |
| `frontend` | Flutter work |
| `backend` | Backend work |

Open a pull request into `main`. Backend changes run lint, type checks and tests; frontend pull requests get a Firebase Hosting preview link. GitGuardian scans pull requests for secrets.

## Security

- Never commit credentials. Local secrets go in `backend/.env` (git-ignored); cloud secrets go in Secret Manager.
- Report suspected vulnerabilities privately to the maintainers rather than in a public issue.
