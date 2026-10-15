# PruFlo

Asynchronous evidence processing with human-controlled decisions, on Google Cloud (asia-southeast1).

> Core invariant: software calculates and validates; AI extracts or explains; an authorized human makes the substantive decision.

## Repository layout

| Folder | Contents |
| --- | --- |
| `frontend/` | Flutter client (web, Android, iOS) |
| `backend/` | Python services: FastAPI API on Cloud Run, processing worker, report generation |
| `Docs/` | Technical architecture report |

## Branches

| Branch | Purpose |
| --- | --- |
| `main` | Integrated, reviewed code |
| `frontend` | Flutter client work; merge to `main` by pull request |
| `backend` | Backend work; merge to `main` by pull request |
