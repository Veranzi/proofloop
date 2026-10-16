# PruFlo Integrations: API contract for the backend

The frontend now has an **Integrations** area (admin only) and a **findings export** on the Reports page. Both run on mock data until the endpoints below exist. This document is the contract the screens were built against. If you need to change a shape, update this file and tell the frontend developer, so the screens and the API stay in step.

Endpoint numbers continue the numbering already used in `frontend/lib/core/api_endpoints.dart` (1–33).

## Where the frontend code lives

| What | File |
| --- | --- |
| Endpoint paths (34–50) | `frontend/lib/core/api_endpoints.dart` |
| Models and enum wire values | `frontend/lib/core/integration_models.dart` |
| Mock data, one method per endpoint | `frontend/lib/core/integrations_repository.dart` |
| Export sample (JSON and CSV) | `frontend/lib/core/case_export.dart` |
| Screens | `frontend/lib/features/integrations/` and `frontend/lib/features/reports/reports_screen.dart` |

When an endpoint is ready, the frontend replaces the body of the matching repository method with an HTTP call. The screens don't change.

## Conventions

These apply to every endpoint here and match the architecture report.

- **Versioned routes** under `/v1`. Everything under `/v1/admin` requires the `admin` role, checked on the server on every request.
- **IDs** are opaque strings with a type prefix (`key_`, `wh_`, `rule_`, `fnd_`, `clm_`, `evd_`). The frontend never parses them.
- **Timestamps** are ISO 8601 in UTC, e.g. `2026-10-16T09:30:00Z`.
- **Numbers that matter** (money, quantities, tolerances) are sent as **strings** (`"0.5"`, `"100"`) and stored as `NUMERIC`. Never use floats.
- **Enums** use the snake_case wire values listed in each section. The frontend maps them in `integration_models.dart`.
- **Errors** use one envelope:

  ```json
  { "error": { "code": "validation_failed", "message": "url must use https", "field": "url", "request_id": "req_8f2a" } }
  ```

- **Lists** return `{ "items": [...], "next_cursor": null }`.
- **Audit**: every create, update, revoke and delete in this document writes an `audit_events` row (actor, action, target, request ID).

## 1. Authentication: two kinds of caller

| Caller | Header | Identity comes from |
| --- | --- | --- |
| A person in the app | `Authorization: Bearer <Firebase ID token>` and `X-Firebase-AppCheck` | Verified Firebase token (unchanged) |
| Another system | `Authorization: Bearer pf_live_<32 chars>` | API key lookup |

Tell the two apart by the `pf_live_` prefix before trying Firebase verification.

**API key rules**

- Generate 32 random characters from a cryptographically secure source. Store only a **SHA-256 hash** of the full key plus the first 12 characters (`prefix`) for display. The full key is returned **once**, in the create response.
- A key belongs to one tenant and acts only within it. Case-level permissions still apply.
- Scopes: `cases:read`, `cases:write`, `evidence:write`, `findings:read`, `reports:read`.
- **A key can never record a review decision** (endpoint 15) or call any `/v1/admin` route, whatever its scopes. Only a signed-in person decides; this is the product's core rule.
- Update `last_used_at` at most once a minute per key, so it doesn't cost a write on every request.
- Revoking a key is permanent. Keep the row so the audit trail stays readable.
- Rate-limit per key (suggested: 600 requests per minute) and return `429` with `Retry-After`.

### 34 `GET /v1/admin/api-keys`

```json
{
  "items": [
    {
      "id": "key_01",
      "name": "Odoo sync job",
      "prefix": "pf_live_7Hq2",
      "scopes": ["cases:write", "evidence:write"],
      "created_at": "2026-10-04T08:00:00Z",
      "created_by": { "uid": "u_123", "name": "Michael Brown" },
      "last_used_at": "2026-10-16T06:10:00Z",
      "revoked": false
    }
  ],
  "next_cursor": null
}
```

### 35 `POST /v1/admin/api-keys`

Request:

```json
{ "name": "Odoo sync job", "scopes": ["cases:write", "evidence:write"] }
```

Response `201`: the same object as in the list, plus `"secret": "pf_live_..."`. This is the only time `secret` is ever returned.

Validation: `name` 1–80 characters; at least one scope; unknown scopes return `400`.

### 36 `DELETE /v1/admin/api-keys/{keyId}`

Revokes the key. Returns `204`. Requests with the key fail with `401` straight away.

## 2. Webhooks

PruFlo POSTs to registered URLs when events happen, so other systems don't need to poll.

### Events

| Wire value | When it fires | `data` contains |
| --- | --- | --- |
| `evidence.processed` | Worker finished an evidence file | `case_id`, `evidence_id`, `status` |
| `evidence.failed` | Evidence reached `failed_terminal` | `case_id`, `evidence_id`, `error_class` |
| `case.review_required` | Case moved to `review_required` | `case_id`, `open_findings` |
| `finding.decided` | A reviewer confirmed, corrected or dismissed a finding | `case_id`, `finding_id`, `decision`, `actor_uid` |
| `case.reviewed` | Every finding in the case has a decision | `case_id` |
| `report.ready` | PDF report or data export generated | `case_id`, `report_id`, `format` |
| `ping` | Test button (endpoint 41) | `{}` |

### Delivery format

```http
POST https://receiver.example.com/hooks/pruflo
Content-Type: application/json
X-Pruflo-Event: finding.decided
X-Pruflo-Delivery: dlv_51b0
X-Pruflo-Signature: t=1760607000,v1=5f2c...e9

{
  "id": "evt_9a77",
  "type": "finding.decided",
  "created_at": "2026-10-16T09:30:00Z",
  "tenant_id": "ten_acme",
  "data": { "case_id": "PL-001", "finding_id": "fnd_7c1e", "decision": "confirmed", "actor_uid": "u_456" }
}
```

- **Signature**: `v1 = hex(HMAC_SHA256(signing_secret, "{t}.{raw_body}"))`. Receivers should reject requests whose `t` is more than 5 minutes old. The UI already tells admins to check `X-Pruflo-Signature`.
- **Payloads carry IDs, not document content.** Receivers fetch details through the API with an API key. That keeps evidence text out of third-party logs.
- `id` is stable across retries, so receivers can drop duplicates.
- **Only HTTPS** URLs are accepted. Reject URLs that resolve to private, loopback or link-local addresses, and the cloud metadata address, both when saving the URL and again before each delivery, to prevent server-side request forgery (SSRF).
- **Retries**: any response other than 2xx, or a 10-second timeout, counts as a failure. Retry with exponential backoff (1 min, 5 min, 30 min, 2 h, 6 h, 12 h), up to 24 hours. Then mark it failed. After 3 days of continuous failures, pause the endpoint and email the admins.
- Send deliveries from the worker through Pub/Sub, never from the request path. Write each event to an outbox in the same transaction as the change that caused it.

### 37 `GET /v1/admin/webhooks`

Each item includes its last 5 deliveries, so the screen can show them without a second call.

```json
{
  "items": [
    {
      "id": "wh_01",
      "url": "https://erp.example.com/hooks/pruflo",
      "description": "ERP exception queue",
      "events": ["case.review_required", "finding.decided"],
      "active": true,
      "created_at": "2026-10-07T10:00:00Z",
      "recent_deliveries": [
        { "id": "dlv_51b0", "event": "finding.decided", "status_code": 200, "attempt": 1, "at": "2026-10-16T08:30:00Z" },
        { "id": "dlv_51a9", "event": "case.review_required", "status_code": 503, "attempt": 2, "at": "2026-10-16T05:30:00Z" }
      ]
    }
  ],
  "next_cursor": null
}
```

`status_code` is `0` when the receiver couldn't be reached at all (DNS failure, timeout or TLS error).

### 38 `POST /v1/admin/webhooks`

Request: `{ "url": "...", "description": "...", "events": ["..."] }`. Response `201`: the endpoint object plus `"signing_secret": "whsec_..."`, returned only once. Store the secret in Secret Manager or encrypted at rest. Unlike API keys it can't be hashed, because you need it to sign.

### 39 `PATCH /v1/admin/webhooks/{webhookId}`

Body: any of `{ "active": false, "events": [...], "description": "..." }`. Returns the updated object.

### 40 `DELETE /v1/admin/webhooks/{webhookId}`

Returns `204`.

### 41 `POST /v1/admin/webhooks/{webhookId}/test`

Sends a `ping` straight away (no retries) and returns the delivery: `{ "id": "dlv_...", "event": "ping", "status_code": 200, "attempt": 1, "at": "..." }`.

### 42 `GET /v1/admin/webhooks/{webhookId}/deliveries?cursor=`

Full paginated delivery log. Keep it for 30 days. Not shown in the UI yet; it's there for support.

## 3. Document sources (connectors)

Every imported file goes through the **same** path as a manual upload: create an `evidence_files` row, run the same type and size checks, compute the checksum on the server, then hand the file to the worker. Connectors only change where the bytes come from.

| `kind` | How it connects | Notes |
| --- | --- | --- |
| `email_inbox` | No input. Server generates an address such as `evidence+acme@in.pruflo.app` | **Build this one first.** Attachments go to a new case, or to an existing one if the subject contains `[PL-001]`. Check sender SPF/DKIM results and apply the same file limits. |
| `google_drive` | Folder link → OAuth (read-only scope on that folder) | Poll every 15 minutes, as the UI says, or use Drive push notifications. |
| `sharepoint` | Library URL → Microsoft OAuth (`Sites.Selected`) | Same as Drive. |
| `odoo` | URL, database, username, API key | Read-only Odoo user. Pull purchase orders, receipts and vendor bills as documents. |
| `sap` | Not built | The UI shows "Coming soon". Return `status: "coming_soon"`. |

Credentials and OAuth refresh tokens go to **Secret Manager** and are **never returned** by any endpoint.

### 43 `GET /v1/admin/connectors`

Returns all five kinds, always.

```json
{
  "items": [
    { "kind": "email_inbox", "status": "connected", "detail": "evidence+acme@in.pruflo.app", "connected_at": "2026-09-26T09:00:00Z" },
    { "kind": "google_drive", "status": "not_connected", "detail": "", "connected_at": null },
    { "kind": "sap", "status": "coming_soon", "detail": "", "connected_at": null }
  ]
}
```

`status` is one of `not_connected`, `connected`, `error` or `coming_soon`. When it's `error`, `detail` holds a message a person can read, e.g. "Odoo rejected the API key".

### 44 `PUT /v1/admin/connectors/{kind}`

| `kind` | Request body | Response |
| --- | --- | --- |
| `email_inbox` | `{}` | Connector object, status `connected` |
| `google_drive`, `sharepoint` | `{ "folder": "<link>", "return_url": "https://pruflo.web.app/integrations" }` | `{ "authorization_url": "https://accounts.google.com/..." }`. The frontend redirects there; your OAuth callback stores the token and redirects to `return_url?connector=google_drive&status=connected` |
| `odoo` | `{ "url": "...", "database": "...", "username": "...", "api_key": "..." }` | Test the login first. On success, the connector object with `detail` set to the Odoo URL; on failure, `400` with a readable message |

### 45 `DELETE /v1/admin/connectors/{kind}`

Delete the stored credentials and stop importing. Evidence already imported stays where it is. Returns `204`.

## 4. Reconciliation rules

Rules are **code in the backend**. A tenant can only turn a rule on or off and set its parameters; the UI never sends formulas. Each rule instance belongs to a tenant and is created from a template.

| `template` | Inputs | Parameters |
| --- | --- | --- |
| `quantity_shortfall` | ordered vs delivered quantity, same unit | `tolerance_units` |
| `amount_mismatch` | invoice total vs PO total, same currency | `tolerance_percent` |
| `delivery_date_window` | delivery date vs promised date | `grace_days` |
| `missing_document` | an order with no matching delivery note or invoice | none |

**Versioning (important for reproducibility).** Changing a parameter creates a new version row. The old one is kept, never edited. Every finding stores `rule_id` and `rule_version`, so a past finding can always be re-run with the parameters that produced it. Turning a rule on or off does **not** create a version.

Validation: parameters are non-negative decimals, and `tolerance_percent` is at most 100. Reject unknown keys. Incompatible units or currencies make the rule emit a data-quality issue, never a silent conversion (see section 7.3 of the architecture report).

### 46 `GET /v1/admin/rules`

```json
{
  "items": [
    {
      "id": "rule_qty",
      "template": "quantity_shortfall",
      "name": "Quantity shortfall",
      "description": "Ordered quantity vs delivered quantity, same unit.",
      "version": 3,
      "enabled": true,
      "params": [
        { "key": "tolerance_units", "label": "Allowed difference", "value": "0", "suffix": "units" }
      ]
    }
  ]
}
```

`label` and `suffix` come from the template, so new templates show up in the UI without a frontend release.

### 47 `PATCH /v1/admin/rules/{ruleId}`

Body: `{ "enabled": false }` or `{ "params": { "tolerance_units": "2" } }`. Returns the updated rule, with `version` incremented if any parameter changed. The change applies to evidence processed after it; existing findings aren't recalculated.

## 5. Processing providers

The worker should call OCR and AI through two small interfaces, so a client who can't use Google Cloud can still be served. A sketch:

```python
class OcrProvider(Protocol):
    name: str      # "google_document_ai"
    version: str   # processor ID / version, recorded on every page
    def extract(self, file: bytes, mime_type: str) -> list[Page]: ...  # text blocks + bounding boxes

class ClaimExtractor(Protocol):
    name: str      # "vertex_gemini"
    model: str     # "gemini-2.5-flash"
    def extract(self, pages: list[Page], schema: dict) -> list[RawClaim]: ...  # output is still validated in code
```

Grounding, rules, versioning and review stay the same whichever provider runs.

| `ocr` wire values | `ai` wire values |
| --- | --- |
| `google_document_ai`, `azure_document_intelligence`, `aws_textract`, `self_hosted` | `vertex_gemini`, `vertex_claude`, `azure_openai`, `self_hosted` |

You only need to implement `google_document_ai` and `vertex_gemini` now. For any other value, return `400 provider_not_available` until its adapter exists. The frontend lists all options so the setting is ready.

### 48 `GET /v1/admin/providers`

```json
{ "ocr": "google_document_ai", "ai": "vertex_gemini", "model": "gemini-2.5-flash", "region": "asia-southeast1" }
```

### 49 `PUT /v1/admin/providers`

Same body as the response above. Before saving, validate that:

- the provider has an adapter;
- the model ID is on a server-side allowlist (no free-text model names reach Vertex);
- the provider offers that model or processor in the chosen region. From our research, Document AI has only limited single-region support in `asia-southeast1` and needs an access request, while Gemini 2.5 models have in-region processing there. Re-check both against Google's docs.

Changes apply to evidence processed afterwards. Record `ocr`, `ai`, `model` and `region` on every claim, as section 5.1 of the architecture report already requires.

Provider **credentials** are configured on the server (service accounts, Secret Manager). This endpoint never takes or returns secrets.

**Region and Kenyan data.** The region list in the UI is `asia-southeast1`, `africa-south1` and `europe-west1`. Storing Kenyan personal data outside Kenya is a cross-border transfer under the Data Protection Act, 2019, and the ODPC issued transfer guidance in 2026. The UI warns admins about this; the legal decision still has to be made before real documents are used.

## 6. Findings export (JSON and CSV)

### 50 `GET /v1/cases/{caseId}/export?format=json|csv`

- Scope `findings:read` for API keys; normal case membership for people.
- Built **only** from stored claims, findings and review actions, the same rule as the PDF report.
- Small cases: return the file directly with `Content-Disposition: attachment; filename="case-PL-001-findings.json"`. Large cases: return `202` with a `report_id`, generate it in the worker, fire `report.ready`, and serve it through the existing download-URL endpoint (19).

JSON (`schema_version` lets the shape change later without breaking receivers):

```json
{
  "schema_version": "1.0",
  "case": { "id": "PL-001", "title": "Fraud Investigation", "status": "reviewed" },
  "generated_at": "2026-10-16T09:30:00Z",
  "findings": [
    {
      "id": "fnd_7c1e",
      "rule_id": "quantity_shortfall",
      "rule_version": 3,
      "type": "quantity_shortfall",
      "severity": "high",
      "expected":   { "value": "100", "unit": "units" },
      "observed":   { "value": "80",  "unit": "units" },
      "difference": { "value": "20",  "unit": "units" },
      "review": { "status": "confirmed", "by": "Sarah Johnson", "at": "2026-10-16T09:10:00Z", "note": "Supplier confirmed 20 units back-ordered." },
      "explanation": "The purchase order lists 100 units; the delivery note records 80 units received.",
      "explanation_source": "machine_generated",
      "evidence": [
        {
          "claim_id": "clm_a01", "field": "ordered_quantity", "value": "100",
          "evidence_id": "evd_po_001", "file_name": "purchase_order.pdf", "page": 1,
          "quote": "Qty ordered: 100", "grounding": "grounded",
          "source_url": "/v1/cases/PL-001/evidence/evd_po_001/view-url?page=1"
        }
      ]
    }
  ]
}
```

- `review.status` is `open`, `confirmed`, `corrected` or `dismissed`. A `corrected` finding also has `review.previous` and `review.new`.
- `grounding` is `grounded`, `ambiguous`, `ungrounded` or `needs_review`.
- `source_url` is a **relative API path**, not a signed URL. Signed URLs expire, and they must not end up in exported files.

CSV has one row per finding, a header row, RFC 4180 quoting and UTF-8 encoding:

```
case_id,finding_id,rule_id,rule_version,severity,expected,observed,difference,unit,review_status,reviewed_by,reviewed_at,evidence
PL-001,fnd_7c1e,quantity_shortfall,3,high,100,80,20,units,confirmed,Sarah Johnson,2026-10-16T09:10:00Z,purchase_order.pdf p1; delivery_note.pdf p1
```

The frontend's sample generator (`case_export.dart`) produces exactly these shapes, and `frontend/test/integrations_test.dart` checks them.

## Suggested build order

1. API-key authentication (section 1). Everything else depends on it.
2. Export (50). It's small and immediately useful to clients.
3. Webhooks (37–42), with the outbox and Pub/Sub delivery.
4. Rules (46–47), when the rule engine from Phase 1 exists.
5. The email inbox connector, then Odoo.
6. Providers (48–49): read-only at first, returning the Google defaults.

## Open questions for the backend

- Should one key be able to span several tenants, for a partner who serves many clients? This document assumes no.
- Should `finding.decided` include the corrected values, or only IDs? This document says only IDs.
- What file and page limits apply to emailed attachments?
- How long are webhook delivery logs and revoked keys kept? Suggested: 30 days for logs, indefinitely for keys (they're audit records).
