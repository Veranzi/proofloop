"""Settings read from environment variables prefixed with PRUFLO_.

On Cloud Run, secrets (such as the database URL) are mounted from Secret
Manager as environment variables, so the code reads them the same way.
"""

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

# Upload limits shared with the frontend (Docs/backend_plan.md, Step 0).
MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_PAGES = 200
MAX_FILES_PER_BATCH = 20


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PRUFLO_", env_file=".env", extra="ignore")

    env: Literal["local", "test", "dev", "staging", "prod"] = "local"
    database_url: str = "postgresql+psycopg://pruflo:pruflo@localhost:5433/pruflo"
    gcp_project: str = "pruflo-local"
    region: str = "asia-southeast1"
    evidence_bucket: str = "pruflo-evidence-local"
    pubsub_topic: str = "evidence-jobs"
    signed_url_minutes: int = 10
    # "gcs" on Cloud Run; "local" stores files on disk and serves uploads from this API.
    storage_backend: Literal["gcs", "local"] = "local"
    local_storage_dir: str = ".local-storage"
    # Signs local upload links. Local and test only; GCS uses Google-signed URLs.
    local_signing_key: str = "local-dev-only"  # noqa: S105
    public_base_url: str = "http://localhost:8000"

    # Local only: accept "Bearer dev:<uid>:<email>" in place of a Firebase token.
    # Refused outside local and test environments (see app.auth.firebase).
    auth_dev_mode: bool = False
    # App Check is skipped in local and test, and enforced everywhere else.
    app_check_required: bool = True


@lru_cache
def get_settings() -> Settings:
    return Settings()
