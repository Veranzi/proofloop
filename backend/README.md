# Pruflo backend

Python services for Pruflo on Google Cloud (asia-southeast1, Singapore):

- **Cloud Run API** (FastAPI) – token validation, case-level authorization, signed URLs, Cloud SQL access.
- **Cloud Run worker** – Pub/Sub-driven evidence pipeline: Document AI OCR, Gemini extraction, grounding, findings.
- **Report generation** – HTML template to PDF.

## Run locally

```bash
python -m venv .venv
.venv\Scripts\activate        # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Then open http://127.0.0.1:8000/healthz or http://127.0.0.1:8000/docs.
