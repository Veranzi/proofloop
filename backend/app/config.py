"""Settings read from environment variables prefixed with PRUFLO_.

On Cloud Run, secrets (such as the database URL) are mounted from Secret
Manager as environment variables, so the code reads them the same way.
"""

import secrets
from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import URL

# Upload limits shared with the frontend (Docs/backend_plan.md, Step 0).
MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_PAGES = 200
MAX_FILES_PER_BATCH = 20


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PRUFLO_", env_file=".env", extra="ignore")

    env: Literal["local", "test", "dev", "staging", "prod"] = "local"
    # On Cloud Run the full URL comes from Secret Manager as PRUFLO_DATABASE_URL.
    # Locally it's built from the parts below; the password lives only in the
    # git-ignored backend/.env, which docker-compose.yml reads too.
    database_url: str = ""
    db_user: str = "pruflo"
    db_password: str = ""
    db_host: str = "localhost"
    db_port: int = 5433
    db_name: str = "pruflo"
    gcp_project: str = "pruflo-local"
    region: str = "asia-southeast1"
    evidence_bucket: str = "pruflo-evidence-local"
    pubsub_topic: str = "evidence-jobs"
    signed_url_minutes: int = 10
    # "gcs" on Cloud Run; "local" stores files on disk and serves uploads from this API.
    storage_backend: Literal["gcs", "local"] = "local"
    local_storage_dir: str = ".local-storage"
    # Signs local upload links. Local and test only; GCS uses Google-signed URLs.
    local_signing_key: str = Field(default_factory=lambda: secrets.token_urlsafe(32))
    public_base_url: str = "http://localhost:8000"
    # "pubsub" on Cloud Run. "inline" runs jobs in this process right after the
    # request (local development), so no Pub/Sub emulator is needed.
    queue_backend: Literal["pubsub", "inline"] = "inline"
    # The worker accepts calls only with a Google-signed OIDC token for this
    # audience (the worker's URL) from one of these service accounts
    # (the Pub/Sub push and Cloud Scheduler identities).
    worker_push_audience: str = ""
    worker_invoker_service_accounts: list[str] = []
    # Document AI OCR. Leave the processor empty to run without OCR: scanned
    # pages and images are then marked needs_review. There's no default
    # location on purpose: choosing one outside asia-southeast1 sends documents
    # out of the region, which needs sign-off (Docs/backend_plan.md, Step 0).
    documentai_location: str = ""
    documentai_processor_id: str = ""

    # Encrypts secrets the API must read back, such as webhook signing secrets
    # (a Fernet key: python -c "from cryptography.fernet import Fernet;
    # print(Fernet.generate_key().decode())"). Required outside local and test.
    secrets_key: str = ""

    # Browser origins allowed to call the API (the Flutter web app).
    cors_origins: list[str] = ["https://pruflo.web.app", "https://pruflo.firebaseapp.com"]

    # Local only: accept "Bearer dev:<uid>:<email>" in place of a Firebase token.
    # Refused outside local and test environments (see app.auth.firebase).
    auth_dev_mode: bool = False
    # App Check is skipped in local and test, and enforced everywhere else.
    app_check_required: bool = True

    @property
    def sqlalchemy_url(self) -> str:
        if self.database_url:
            return self.database_url
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password or None,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        ).render_as_string(hide_password=False)


@lru_cache
def get_settings() -> Settings:
    return Settings()
