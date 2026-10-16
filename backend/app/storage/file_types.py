"""Accepted evidence files (Docs/backend_plan.md, Step 0, "File limits and types").

The extension and the declared type are only a first filter. ``detect`` reads
the file's first bytes on the server, and that result decides.
"""

import io
import zipfile
from dataclasses import dataclass


@dataclass(frozen=True)
class FileType:
    mime: str  # canonical type we store and serve
    declared: frozenset[str]  # types browsers commonly send for this extension
    kind: str  # "documents" or "images", as on the upload screen


_PDF = FileType("application/pdf", frozenset({"application/pdf"}), "documents")
_DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
_XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
_OCTET = "application/octet-stream"

FILE_TYPES: dict[str, FileType] = {
    ".pdf": _PDF,
    ".docx": FileType(_DOCX_MIME, frozenset({_DOCX_MIME, _OCTET}), "documents"),
    ".xlsx": FileType(_XLSX_MIME, frozenset({_XLSX_MIME, _OCTET}), "documents"),
    ".csv": FileType(
        "text/csv",
        frozenset({"text/csv", "application/csv", "application/vnd.ms-excel", "text/plain"}),
        "documents",
    ),
    ".txt": FileType("text/plain", frozenset({"text/plain"}), "documents"),
    ".jpg": FileType("image/jpeg", frozenset({"image/jpeg"}), "images"),
    ".jpeg": FileType("image/jpeg", frozenset({"image/jpeg"}), "images"),
    ".png": FileType("image/png", frozenset({"image/png"}), "images"),
    ".tif": FileType("image/tiff", frozenset({"image/tiff"}), "images"),
    ".tiff": FileType("image/tiff", frozenset({"image/tiff"}), "images"),
}


def extension_of(file_name: str) -> str:
    dot = file_name.rfind(".")
    return file_name[dot:].lower() if dot > 0 else ""


def _is_text(head: bytes) -> bool:
    if b"\x00" in head:
        return False
    try:
        head.decode("utf-8")
    except UnicodeDecodeError as exc:
        # A multi-byte character may be cut at the end of the sample.
        if exc.start < len(head) - 3:
            try:
                head.decode("cp1252")
            except UnicodeDecodeError:
                return False
    return True


def _office_kind(data: bytes) -> str | None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = set(archive.namelist())
    except zipfile.BadZipFile:
        return None
    if "[Content_Types].xml" not in names:
        return None
    if any(n.startswith("word/vbaProject") or n.startswith("xl/vbaProject") for n in names):
        return None  # macro-enabled files are refused
    if "word/document.xml" in names:
        return _DOCX_MIME
    if "xl/workbook.xml" in names:
        return _XLSX_MIME
    return None


def detect(data: bytes) -> str | None:
    """The real type of a file from its content, or None if it isn't one we accept."""
    head = data[:16]
    if head.startswith(b"%PDF-"):
        return "application/pdf"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith((b"II*\x00", b"MM\x00*")):
        return "image/tiff"
    if head.startswith(b"PK\x03\x04"):
        return _office_kind(data)
    if _is_text(data[:8192]):
        return "text/plain"  # CSV and TXT are both plain text
    return None


def matches(extension: str, detected: str | None) -> bool:
    expected = FILE_TYPES.get(extension)
    if expected is None or detected is None:
        return False
    if expected.mime in ("text/csv", "text/plain"):
        return detected == "text/plain"
    return detected == expected.mime
