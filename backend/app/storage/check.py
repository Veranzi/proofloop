"""Check the real evidence bucket, the parts the local fake can't show
(Docs/backend_plan.md, Steps 3 and 6):

    PRUFLO_STORAGE_BACKEND=gcs PRUFLO_EVIDENCE_BUCKET=... python -m app.cli check-storage

- The bucket is in the configured region, with uniform access and public
  access prevention enforced.
- A V4 signed PUT URL is accepted, and the size range it was signed with is
  enforced by Cloud Storage (a bigger body is refused).
- Without a signature the object can't be read; with one it can.

Writes and deletes one small object under ``_checks/``.
"""

from collections.abc import Callable
from urllib.parse import quote

import httpx

from app.config import get_settings
from app.ids import new_id
from app.storage.backend import GcsStorage

Report = list[tuple[str, bool, str]]


def check_bucket(storage: GcsStorage, region: str) -> Report:
    report: Report = []

    def step(name: str, test: Callable[[], tuple[bool, str]]) -> None:
        try:
            ok, detail = test()
        except Exception as exc:  # report every check, whatever breaks
            ok, detail = False, f"{type(exc).__name__}: {exc}"
        report.append((name, ok, detail))

    bucket = storage._bucket
    bucket.reload()
    config = bucket.iam_configuration
    report.append(
        (f"bucket is in {region}", (bucket.location or "").lower() == region, bucket.location or "")
    )
    report.append(
        (
            "uniform bucket-level access",
            bool(config.uniform_bucket_level_access_enabled),
            str(config.uniform_bucket_level_access_enabled),
        )
    )
    report.append(
        (
            "public access prevention enforced",
            config.public_access_prevention == "enforced",
            str(config.public_access_prevention),
        )
    )

    key = f"_checks/{new_id('chk')}.txt"
    body = b"pruflo storage check"
    limit = len(body) + 4

    def signed_put() -> tuple[bool, str]:
        signed = storage.upload_request(key, "text/plain", limit)
        res = httpx.put(signed.url, content=body, headers=signed.headers, timeout=30)
        return res.status_code == 200, f"HTTP {res.status_code}"

    def size_limit() -> tuple[bool, str]:
        signed = storage.upload_request(key + ".big", "text/plain", limit)
        res = httpx.put(signed.url, content=body * 3, headers=signed.headers, timeout=30)
        return res.status_code in (400, 403), f"HTTP {res.status_code} for {len(body) * 3} bytes"

    def private() -> tuple[bool, str]:
        url = f"https://storage.googleapis.com/{bucket.name}/{quote(key)}"
        res = httpx.get(url, timeout=30)
        return res.status_code in (401, 403), f"unsigned GET: HTTP {res.status_code}"

    def signed_get() -> tuple[bool, str]:
        signed = storage.view_url(key, "check.txt", "text/plain")
        res = httpx.get(signed.url, timeout=30)
        return res.status_code == 200 and res.content == body, f"HTTP {res.status_code}"

    def stat() -> tuple[bool, str]:
        info = storage.stat(key)
        return info is not None and info.size == len(body), str(info)

    step("signed PUT URL accepted", signed_put)
    step("size range enforced by Cloud Storage", size_limit)
    step("objects aren't readable without a signature", private)
    step("signed GET URL serves the object", signed_get)
    step("server-side stat sees the real size", stat)
    for leftover in (key, key + ".big"):
        storage.delete(leftover)
    return report


def run() -> bool:
    settings = get_settings()
    if settings.storage_backend != "gcs":
        raise ValueError("Set PRUFLO_STORAGE_BACKEND=gcs and PRUFLO_EVIDENCE_BUCKET first.")
    report = check_bucket(GcsStorage(settings.evidence_bucket), settings.region)
    for name, ok, detail in report:
        print(f"{'PASS' if ok else 'FAIL'}  {name}  ({detail})")  # noqa: T201
    return all(ok for _, ok, _ in report)
