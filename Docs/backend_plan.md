# PruFlo backend: implementation plan

A step-by-step summary of how the backend will be built. It follows two existing documents and does not replace them:

- `Docs/Pruflo_GCP_Technical_Architecture_Report.docx`: the architecture, data model, security and roadmap.
- `Docs/Integrations_API_Contract.md`: the exact request and response shapes for endpoints 34–50.

Where this plan differs from the report (region, endpoint paths, review decisions, case statuses), **this plan and the frontend win**. The decisions are listed in Step 0.

Endpoint numbers (1–50) and paths are the ones in `frontend/lib/core/api_endpoints.dart`. The frontend currently runs on mock data (`mock_repository.dart`, `integrations_repository.dart`). Each endpoint we ship replaces one mock method, and the screens stay the same.

## Progress

Last updated 2026-10-16 (Steps 7 and 8). Status is judged against each step's **Done when** line.

✅ done · 🟠 partly done · ❌ not started

| Step | Status | Notes |
| --- | --- | --- |
| 0 Decisions | ✅ | Region, endpoint paths, review decisions, case statuses, roles, file limits |
| 1 Foundation | ✅ | Settings, error envelope, request IDs, JSON logs, paging, Docker services, CI workflow |
| 2 Database | 🟠 | All tables and migrations; separate database roles still to do |
| 3 GCP environment | ❌ | Needs access to the GCP project |
| 4 Authentication | 🟠 | Done locally; real Firebase tokens not yet tested |
| 5 Cases | ✅ | Endpoints 3–6 and 16 |
| 6 Evidence upload | 🟠 | Endpoints 7–11, the Flutter upload screen and outbox publishing; real Cloud Storage bucket needs Step 3 |
| 7 Worker | ✅ | Idempotent jobs, retries, outbox → Pub/Sub, push endpoint; runs inline locally |
| 8 Text extraction | 🟠 | PDF, Word, Excel, CSV, TXT and endpoint 12 done; real Document AI OCR needs Step 3 |
| 9 Gemini extraction | ❌ | Needs Vertex AI in the GCP project |
| 10 Grounding | ❌ | |
| 11 Rule engine | ❌ | |
| 12 Explanations | ❌ | |
| 13 Human review | ❌ | |
| 14 Reports and export | ❌ | |
| 15 Admin | ❌ | Until then, people are invited with `python -m app.cli invite` |
| 16 Integrations | 🟠 | API keys (34–36) done in Step 4; webhooks, connectors and providers not started |
| 17 Hardening | ❌ | |
| 18 Case Q&A (optional) | ❌ | |

Built along the way, not in the original steps:

- `python -m app.cli` commands: `bootstrap`, `invite` and `remove-user`.
- Local storage that stands in for Cloud Storage when `PRUFLO_ENV` is `local` or `test`.
- CORS for `pruflo.web.app` and local development.
- The Flutter upload screen calls the API when built with `--dart-define=USE_API=true`.
- Cases have an internal `id` (`case_...`) and a `reference` people see (`PL-001`).

## The rule everything follows

**Code calculates, AI reads documents and drafts wording, and people decide.**

- Gemini extracts candidate values and quotes the text that supports them. It never does arithmetic and never makes a case decision.
- Every extracted value is grounded: it is traced back to a file, page, text span and, where possible, a bounding box. If it can't be traced, it is marked for review instead of being trusted.
- Reconciliation is done by versioned Python rules that can be re-run and give the same result.
- Only a signed-in person can approve or reject a finding. API keys can't do it, and neither can the model.

## Target stack and layout

Python 3.12, FastAPI, Pydantic v2, SQLAlchemy 2 + Alembic, firebase-admin, google-cloud clients (Storage, Pub/Sub, Document AI, Vertex AI), pypdf/pdfplumber, python-docx, openpyxl, WeasyPrint, pytest, Ruff, mypy.

```
backend/
  app/
    main.py              # API service entry point
    config.py            # settings from env / Secret Manager
    enums.py             # CaseStatus, ReviewDecision, Role: the single source of wire values
    api/v1/              # one router per area: me, cases, evidence, findings, reports, admin, integrations
    auth/                # Firebase token, App Check, API keys, permission checks
    db/                  # models, session, Alembic migrations
    services/            # business logic called by routers and the worker
    storage/             # signed URLs, object checks
    pipeline/            # extract → claims → grounding → rules → explanation
      parsers/           # pdf, docx, xlsx, csv, txt
      providers/         # OcrProvider and ClaimExtractor adapters
      rules/             # quantity_shortfall, amount_mismatch, delivery_date_window, missing_document
    worker/              # Pub/Sub push handler, job runner, outbox dispatcher, webhook sender
    reports/             # HTML templates → PDF, JSON/CSV export
  tests/                 # unit, integration, golden documents
  Dockerfile             # API image
  Dockerfile.worker      # worker image (adds WeasyPrint system packages)
```

The API and the worker share one codebase but run as **two separate Cloud Run services**, each with its own service account.

---

## ✅ Step 0: decisions (settled)

These are fixed. The frontend, the contract and the backend all use exactly these values.

### Region: `asia-southeast1` (Singapore)

- PruFlo is built for the **Southeast Asian market**: Singapore, Malaysia and Indonesia.
- Every resource goes in `asia-southeast1`: Cloud Run, Cloud SQL, Cloud Storage, Pub/Sub, Artifact Registry, and the logs bucket.
- `asia-southeast2` (Jakarta) is the second region the provider settings offer, for a client who needs its data held in Indonesia.
- **Check first:** whether Document AI and Vertex AI Gemini serve `asia-southeast1`. If one doesn't, process digital files (PDF, DOCX, XLSX, CSV, TXT) with our own parsers in-region, and treat calling OCR or Gemini in another region as a decision that needs sign-off. Never fall back to another region silently.

### Endpoint paths: the frontend's paths

Use `frontend/lib/core/api_endpoints.dart` as the source of truth. The report's paths (such as `/v1/evidence/{id}/complete`) are not used. Endpoint 8 is added on both sides:

| # | Method and path | Purpose |
| --- | --- | --- |
| 1, 21 | `GET`, `PATCH /v1/me` | Profile |
| 2, 22 | `POST /v1/devices`, `DELETE /v1/devices/{id}` | Push notification tokens |
| 23 | `GET /v1/me/activity` | My activity |
| 3, 4 | `GET`, `POST /v1/cases` | List and create cases |
| 5, 6 | `GET`, `PATCH /v1/cases/{caseId}` | Get and update a case |
| 7 | `POST /v1/cases/{caseId}/evidence/upload-url` | Signed upload URL |
| **8** | `POST /v1/cases/{caseId}/evidence/{evidenceId}/complete` | Verify the upload and queue processing (**new**: add to `api_endpoints.dart`) |
| 9 | `GET /v1/cases/{caseId}/evidence` | Evidence list with status |
| 10 | `POST /v1/cases/{caseId}/evidence/{evidenceId}/retry` | Retry processing |
| 11 | `GET /v1/cases/{caseId}/evidence/{evidenceId}/view-url` | Signed view URL |
| 12 | `GET /v1/cases/{caseId}/evidence/{evidenceId}/anchors` | Page text and boxes |
| 13 | `GET /v1/cases/{caseId}/claims` | Extracted claims |
| 14 | `GET /v1/cases/{caseId}/findings` | Findings |
| 15 | `POST /v1/cases/{caseId}/findings/{findingId}/decision` | Review decision |
| 16 | `GET /v1/cases/{caseId}/timeline` | Case timeline |
| 17, 18 | `POST`, `GET /v1/cases/{caseId}/reports` | Create and list reports |
| 19 | `GET /v1/cases/{caseId}/reports/{reportId}/download-url` | Signed download URL |
| 20 | `POST /v1/cases/{caseId}/qa` | Optional case Q&A |
| 24–33 | `/v1/admin/users`, `/customers`, `/cases/{caseId}/members`, `/audit` | Admin |
| 34–49 | `/v1/admin/api-keys`, `/webhooks`, `/connectors`, `/rules`, `/providers` | Integrations (see contract) |
| 50 | `GET /v1/cases/{caseId}/export?format=json\|csv` | Findings export |

### Review decision: `approve`, `reject`, `pending`

| Dart (`ReviewDecision`) | Wire and database value | Meaning |
| --- | --- | --- |
| `approve` | `approve` | The reviewer accepts the finding |
| `reject` | `reject` | The reviewer rejects the finding. **A note is required** |
| `pending` | `pending` | No decision yet, or more information is needed. **Every finding starts here.** A note is required when a reviewer sets it |

- A reviewer can correct an extracted value as part of a decision. The correction is stored on the review action as `{field, previous, new}`; it is not a separate decision.
- The same values appear in the decision endpoint (15), `findings.review_status`, `review_actions.decision`, the `finding.decided` webhook, the JSON export and the CSV `review_status` column.

### Case status: `awaitingEvidence`, `inReview`, `completed`

| Dart (`CaseStatus`) | Wire and database value | When |
| --- | --- | --- |
| `awaitingEvidence` | `awaiting_evidence` | New case, or evidence still uploading or processing |
| `inReview` | `in_review` | Processing finished and at least one finding is `pending` |
| `completed` | `completed` | No finding is `pending` |

- Wire values are snake_case, following the contract's convention. The Dart enums carry the mapping in a `wire` field (`frontend/lib/core/models.dart`).
- A new upload to a `completed` case moves it back to `awaiting_evidence`. Each change goes through one transition function and writes an audit event.
- Webhook events follow the same names: `case.in_review` and `case.completed`.
- Processing state is tracked **per evidence file**, separately from the case status: `queued → extracting → grounding → reconciling → processed | needs_review | failed_retryable | failed_terminal`.

### Roles and permissions

Roles: `investigator`, `reviewer`, `admin`, `viewer`. Each user has one role per tenant; access to a case also requires case membership (admins see every case in their tenant).

| Action | investigator | reviewer | admin | viewer |
| --- | --- | --- | --- | --- |
| View cases, evidence and findings | ✓ | ✓ | ✓ | ✓ |
| Create and edit cases, upload evidence | ✓ | | ✓ | |
| Record a review decision (15) | | ✓ | ✓ | |
| **Export: PDF report and JSON/CSV (17–19, 50)** | ✓ | ✓ | ✓ | ✗ |
| Admin and integrations (`/v1/admin/*`) | | | ✓ | |

API keys use scopes instead of roles and can never record a decision or call `/v1/admin`.

### File limits and types

- **25 MB per file.** This handles realistic scanned documents, matches common email attachment limits (so the email connector uses the same limit), and keeps worker memory and OCR cost predictable.
- **200 pages per document, 20 files per upload batch.** Larger files are rejected with a clear message.
- **Accepted types** are checked by extension **and** by the file's actual content on the server, never by the client's declared type alone:

| Kind | Extensions | How text is read |
| --- | --- | --- |
| Documents | `.pdf` | PDF text layer; OCR when a page has none (scanned) |
| | `.docx` | python-docx |
| | `.xlsx` | openpyxl (values, not formulas; sheet and cell kept as the anchor) |
| | `.csv`, `.txt` | Plain read, UTF-8 with a fallback encoding check |
| Images (scans and photos) | `.jpg`, `.jpeg`, `.png`, `.tif`, `.tiff` | OCR |

- Not accepted: video and audio (they can't be reconciled), macro-enabled Office files (`.docm`, `.xlsm`), and legacy `.doc`/`.xls`. Archives are also not accepted.
- The frontend upload screen already uses this list and limit.

**Still to confirm:** retention periods for evidence, reports and logs.

## ✅ Step 1: project foundation

> **Status:** done. The GitHub Actions check runs once the `backend` branch is pushed.


- Split `app/` into the layout above, with settings loaded from environment variables (later from Secret Manager).
- Create `app/enums.py` with `CaseStatus`, `ReviewDecision` and `Role`, using the Step 0 wire values. Every model, schema and test imports from it; nothing else defines these strings.
- Add shared conventions from the start: the error envelope (`{"error": {code, message, field, request_id}}`), a request-ID middleware, cursor pagination (`{items, next_cursor}`), prefixed opaque IDs (`case_`, `evd_`, `clm_`, `fnd_`...), UTC ISO timestamps, and decimals sent as strings.
- Use structured JSON logging that carries `request_id`, `case_id`, `evidence_id` and `job_id`. Never log document text or signed URLs.
- Add a local `docker-compose.yml` with Postgres, the Pub/Sub emulator and a fake GCS server, so the whole flow runs on a laptop.
- Set up tooling: Ruff, mypy, pytest, pinned dependencies, and a GitHub Actions job that runs them on every PR.

**Done when:** `docker compose up` plus `pytest` pass locally and in CI.

## 🟠 Step 2: database schema and migrations

> **Status:** all 24 tables, constraints and migrations are done; `review_actions` and `audit_events` are append-only through database triggers. **Left:** separate migration and runtime database roles (do this with Step 3).


Create the schema in Alembic, using `NUMERIC` for money and quantities, UUID primary keys, foreign keys and indexes on `case_id`, `evidence_id`, `status`, `created_at` and `rule_id`. Enum columns use check constraints with the Step 0 values.

| Group | Tables |
| --- | --- |
| People | `tenants`, `users`, `memberships` (role per tenant), `case_members`, `devices` |
| Cases | `cases` (`status`: `awaiting_evidence` / `in_review` / `completed`), `evidence_files`, `processing_jobs` |
| Document model | `document_pages`, `text_blocks` |
| AI output | `extracted_claims` (immutable, with model, prompt, schema and OCR versions) |
| Rules | `rules` (tenant instance, on/off), `rule_versions` (append-only parameters) |
| Results | `findings` (with `rule_id`, `rule_version` and `review_status`, default `pending`), `review_actions` (append-only: `decision`, note, optional correction) |
| Output | `reports` |
| Integrations | `api_keys` (hash and prefix only), `webhook_endpoints`, `webhook_deliveries`, `connectors`, `provider_settings` |
| Reliability | `outbox_events` |
| Audit | `audit_events` (append-only) |

- Use separate database roles: a **migration role** that can change the schema, and a **runtime role** that can't update or delete `audit_events` or `review_actions`.
- Every query is scoped by tenant. Add PostgreSQL row-level security later if there's time.

**Done when:** migrations apply cleanly to an empty database and roll back, and there are tests for the main constraints.

## ❌ Step 3: GCP dev environment in `asia-southeast1`

Set this up early so that each later step can be deployed and shown:

- A dev project in `asia-southeast1`; Cloud SQL (Postgres, smallest tier, private IP); a private evidence bucket (uniform access, public access prevention); a Pub/Sub topic with a dead-letter topic. Logs are routed to a log bucket in the same region.
- Service accounts for the `api`, the `worker` and `migrations`, each with only the permissions it needs, and no downloaded key files.
- Artifact Registry, plus a Cloud Build (or GitHub Actions) pipeline: test → build → push an image tagged with the version → deploy to Cloud Run with min instances 0 and a capped max.
- A budget alert from day one.
- Run the Document AI and Gemini availability check from Step 0 and record the result here.

**Done when:** `/healthz` responds from Cloud Run, and the Flutter build with `--dart-define=API_BASE_URL=...` can reach it.

## 🟠 Step 4: authentication and permissions

> **Status:** done: Firebase and App Check verification code, invite-only access, API keys with rate limits, the permission table, and endpoints 1, 2, 21–23 and 34–36. **Left:** verify against real Firebase tokens once a Firebase project is connected (local development uses `dev:` tokens); the export and decision routes this step guards come in Steps 13 and 14.


- **People:** verify the Firebase ID token server-side with firebase-admin, then verify the App Check token from `X-Firebase-AppCheck`. User identity always comes from the verified token, never from the request body.
- **Systems:** `Authorization: Bearer pf_live_...`. Spot the prefix, look up the key by its SHA-256 hash, and apply the key's tenant and scopes. Rate-limit each key and return `429`.
- Write one `require(...)` dependency that checks tenant, role (the Step 0 table) and case membership on **every** route. Keys are always blocked from endpoint 15 and from `/v1/admin`.
- **Endpoints:** 1 `GET /v1/me`, 21 `PATCH /v1/me`, 2 and 22 devices (FCM tokens), 23 my activity; 34–36 API keys.

**Done when:** tests show that a user who isn't a member of a case can't read anything in it (including signed URLs), a `viewer` gets `403` on export, and an API key can't record a decision.

## ✅ Step 5: cases

- **Endpoints:** 3 list (filter by status), 4 create (starts as `awaiting_evidence`), 5 get, 6 update, 16 timeline (built from audit events).
- One `transition_case(case, new_status)` function enforces the Step 0 rules and writes the audit event.

## 🟠 Step 6: evidence upload

> **Status:** endpoints 7–11 work end to end from the Flutter upload screen, including drag and drop. Files are checked on the server, get a job and an outbox event, and the outbox is published (Step 7). **Left:** Cloud Storage signed URLs tested against a real bucket (Step 3).


1. Endpoint **7** `upload-url`: check permission and the declared extension and size against the Step 0 limits, create an `evidence_files` row, and return a short-lived V4 signed PUT URL for an object key **the server chooses**. The URL is bound to the size limit.
2. The client uploads straight to Cloud Storage.
3. Endpoint **8** `complete`: confirm the object exists, check its real size and content type (by reading its first bytes), count pages, and compute the checksum on the server. Then in **one transaction** mark it `queued`, set the case to `awaiting_evidence`, and write an `outbox_events` row.
4. An outbox dispatcher publishes to Pub/Sub. This closes the gap where the database write succeeds but the publish fails.

- **Other endpoints:** 9 list evidence with status, 10 retry, 11 view URL (short-lived signed GET URL).
- Wrong type, oversized, over-page-limit or incomplete uploads are rejected or quarantined.

**Done when:** a file can be uploaded from the Flutter app, the evidence row shows `queued`, and a message reaches Pub/Sub.

## ✅ Step 7: worker and processing pipeline skeleton

> **Status:** done. Jobs are claimed with a 10-minute lease and their results replace earlier ones, so redelivery changes nothing (tested). Permanent errors fail at once; others retry up to 5 times. The worker service (`app/worker/main.py`, `Dockerfile.worker`) takes Pub/Sub pushes and a Cloud Scheduler outbox sweep, both behind OIDC checks. Locally the API runs jobs inline, and `python -m app.worker drain` processes anything waiting. The Pub/Sub and OIDC pieces get their first real run when deployed (Step 3). Case status isn't changed here; reconciliation (Step 11) decides `in_review` or `completed`.

- Pub/Sub pushes to an **authenticated** Cloud Run worker endpoint, which can't be reached from the public internet.
- The worker is idempotent. It works from a `processing_jobs` row with a unique idempotency key, so a redelivered message never duplicates claims, findings or audit rows.
- Evidence status moves through the per-file states from Step 0. When every file in a case is processed and at least one finding is `pending`, the case moves to `in_review`.
- Retries are bounded with exponential backoff, followed by the dead-letter topic. Invalid files and schema failures go straight to `failed_terminal`.
- The worker writes outbox events (`evidence.processed`, `evidence.failed`, `case.in_review`) for webhooks.

**Done when:** a test that delivers the same message twice produces exactly one set of results.

## 🟠 Step 8: text extraction

> **Status:** PDF text layer (lines with positions), Word (paragraphs and table rows), Excel (one page per sheet, rows with cell references), CSV and TXT, plus endpoint 12, are done and tested, including on a real 31-page PDF. Pages with no text layer and images go to OCR. **Left:** the Document AI adapter is written but has only been tested with a stand-in; it needs a processor in the GCP project (Step 3). Until then scans are marked `needs_review` (`ocr_not_configured`).

- **Native parsers first** (cheap, in-region, exact): the PDF text layer, DOCX, XLSX (sheet, row and column kept as the anchor), CSV and TXT.
- **OCR** only for images and PDF pages that have no text layer, through the `OcrProvider` interface (contract §5) with the **Google Document AI** adapter.
- Normalize everything into `document_pages` and `text_blocks` with text spans, bounding boxes (or cell references for spreadsheets), the coordinate system and OCR confidence. Keep the original file untouched.
- Record the parser or processor name and version on every page.
- **Endpoint:** 12 anchors (page text and boxes for the review overlay).

## ❌ Step 9: claim extraction with Gemini

- Define the `ClaimExtractor` interface and the **Vertex Gemini** adapter, with the model ID read from configuration and checked against an allowlist.
- Send only the text that's needed. Give Gemini a strict JSON schema to fill: `field_name, raw_value, normalized_value, source_quote, page_hint, extraction_status`, plus a reason when it can't find a value.
- Validate everything in code against types, enums and maximum lengths. Treat document text as untrusted data: the model gets no tools and no secrets, and nothing it returns is ever executed.
- Save the model, prompt version, schema version, provider and region on every claim.
- **Endpoint:** 13 claims.

## ❌ Step 10: grounding

- Search for each quote in the page (or sheet) text it claims to come from first, normalizing only whitespace and line-wrap differences.
- One match makes the claim `grounded`, with the span and bounding box attached. Several matches make it `ambiguous`, and no match makes it `ungrounded`; either way it goes to `needs_review`.
- Keep table context (row and column labels) so that a bare "80" is never trusted without its label.

**Done when:** golden tests pass for exact, missing and ambiguous quotes.

## ❌ Step 11: rule engine

- Write the four templates from the contract as versioned Python rules with declared inputs, units and parameters: `quantity_shortfall`, `amount_mismatch`, `delivery_date_window` and `missing_document`.
- Incompatible units or currencies produce a data-quality issue, never a silent conversion. `missing_document` reports "no matching evidence found", which is not the same as proof that the delivery never happened.
- Each finding stores the rule ID and version, its inputs (claim IDs), the expected and observed values and the computed difference, and starts with `review_status = pending`.
- **Endpoints:** 14 findings; 46–47 rules (a change to a parameter creates a new version, while turning a rule on or off doesn't).

**Done when:** ordered=100 and delivered=80 gives a shortfall of 20, with no LLM involved.

## ❌ Step 12: explanations

- The default is a **deterministic template** ("The purchase order lists 100 units; the delivery note records 80.").
- An optional Gemini rewrite may use only the finding's own values and quotes. It is labeled `machine_generated`.

## ❌ Step 13: human review

- Endpoint **15** `decision`: body `{ "decision": "approve" | "reject" | "pending", "note": "...", "correction": { "field", "previous", "new" }? }`. `reject` and `pending` require a note. Allowed for reviewers and admins only; people only, never API keys.
- Each decision is an append-only `review_actions` row plus an audit event, and it updates `findings.review_status`.
- When no finding in the case is `pending`, the case moves to `completed`. A finding set back to `pending` moves a completed case back to `in_review`.
- Fires the `finding.decided` and `case.completed` outbox events.

## ❌ Step 14: reports and export

- Allowed for **investigators, reviewers and admins** who are members of the case. Viewers get `403`.
- Endpoints **17** and **18**: queue a report and list reports. The worker renders an HTML template to PDF with WeasyPrint, built only from stored claims, findings and review actions, then saves it to the bucket.
- Endpoint **19**: download URL, a short-lived signed GET URL issued after the permission check.
- Endpoint **50**: JSON and CSV export, matching the contract exactly (`schema_version`, decimals as strings, `review.status` as `pending`/`approve`/`reject`, `source_url` as a relative API path, never a signed URL). Small cases are returned directly; large ones return `202` and go through the worker.
- Fires the `report.ready` event.

**Done when:** the export output matches the shapes the frontend's `integrations_test.dart` checks.

## ❌ Step 15: admin

Endpoints **24–33**: users (list, invite, change role, disable), customers, case members, and the audit log viewer. Every change is audited.

## 🟠 Step 16: integrations

> **Status:** API keys (34–36) are done as part of Step 4. Webhooks, connectors and providers are not started.

Build in this order (from the contract):

1. **Webhooks**, 37–42: HTTPS URLs only, with SSRF checks both when a URL is saved and before each send, HMAC-SHA256 signatures, delivery from the worker via the outbox, the retry schedule up to 24 h, and automatic pausing after 3 days of failures. Signing secrets are kept in Secret Manager.
2. **Connectors**, 43–45: the email inbox first, then Odoo, then Google Drive and SharePoint (OAuth). Imported files go through **the same path and limits** as a manual upload (Step 6). Credentials are never returned.
3. **Providers**, 48–49: read-only at first, returning the defaults (`google_document_ai`, `vertex_gemini`, `asia-southeast1`). Before saving a change, check that an adapter exists, that the model is on the allowlist and that it's offered in the chosen region.

## ❌ Step 17: production hardening

- Cloud Monitoring dashboards and alerts for queue age, processing time, worker failures, OCR and model errors, database connections and cost anomalies.
- Cloud SQL backups kept in-region, plus a restore drill that has actually been run.
- A connection-pool budget sized against the Cloud Run maximum instance count.
- Load tests with synthetic documents at the 25 MB / 200-page limits, a threat-modeling session, and retention and deletion jobs.
- Separate staging and production environments, deployments that record the commit and image digest, and a rollback procedure.
- A data protection impact assessment before any real documents are used.

## ❌ Step 18 (optional): case Q&A

Endpoint **20**: a read-only assistant with three narrow tools (`get_findings`, `get_claims`, `get_timeline`). Every answer cites finding or claim IDs. It has no write tools, and the core workflow never depends on it.

---

## Milestones

| Milestone | Status | Steps | Matches report phase | What you can show |
| --- | --- | --- | --- | --- |
| **M1 Vertical slice** | 🟠 | 0–6, 11 (shortfall rule only), 13, 14 (simple PDF) | Phase 1 | Create a case → upload synthetic documents → see the 20-unit shortfall → approve it → export PDF |
| **M2 Robust ingestion** | 🟠 | 7, 8 | Phase 2 | PDFs, DOCX, XLSX, CSV and scans are all read, with retries and visible statuses |
| **M3 Grounded AI** | ❌ | 9, 10, 12 | Phase 3 | Values come from Gemini with source highlights; uncertain ones are flagged |
| **M4 Review and audit** | ❌ | 13 (full), 15, 16 (keys, export, webhooks) | Phase 4 | Corrections, audit trail, admin, integrations |
| **M5 Hardening** | ❌ | 16 (connectors), 17 | Phase 5 | Monitoring, backups, staging and production |

M1 is partly done: Steps 0, 1 and 5 are complete, and 2, 4 and 6 are mostly done. Step 3 (GCP), the shortfall rule, review and PDF export are still to build.

For M1, claims can come from hand-labelled synthetic documents, so the demo works before the Gemini step exists.

## Acceptance tests (from the report, §11, updated)

- **Arithmetic:** ordered=100 and delivered=80 in the same unit gives a shortfall of 20, computed in code.
- **Grounding:** a unique quote maps to its page and span; a missing or ambiguous quote is flagged.
- **Authorization:** a user who isn't a member can't reach anything in the case, including signed URLs. A viewer can't export, and an API key can't decide.
- **Uploads:** wrong type, over 25 MB, over 200 pages, or incomplete uploads are rejected or quarantined.
- **Idempotency:** a redelivered message creates no duplicates.
- **Review:** every finding starts `pending`; `reject` and `pending` require a note; every decision records the actor, time, decision, note and any correction.
- **Case status:** a case moves `awaiting_evidence → in_review → completed` and back as described in Step 0.
- **Reports:** exports include finding IDs, evidence references, review status and generation time.
- **Failures:** timeouts are retried within limits and end in a visible failed state.
- **Security:** signed URLs expire, buckets are private, and no secrets or document text appear in logs.
- **Region:** every stored resource and backup is in `asia-southeast1`.

## Open questions

- Retention periods for evidence, reports, logs and revoked keys.
- Can one API key span several tenants (for a partner serving many clients)? Assumed no.
- Should `finding.decided` carry the corrected values, or only IDs? Assumed only IDs.
- Do high-impact findings need a second reviewer? Do rejected findings appear in reports?
- Should OCR and PDF rendering share one worker image or use two?
- How is confidence shown, given that model "confidence" isn't a calibrated probability?
