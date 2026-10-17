"""Turn an uploaded file into normalized pages (Docs/backend_plan.md, Step 8)."""

from collections.abc import Callable
from dataclasses import dataclass

from app.pipeline import parsers
from app.pipeline.document import Page
from app.pipeline.errors import PermanentError
from app.pipeline.ocr import OcrProvider

# Keyed by the type the server detected on upload, never the client's claim.
NATIVE: dict[str, Callable[[bytes], list[Page]]] = {
    "application/pdf": parsers.parse_pdf,
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": parsers.parse_docx,
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": parsers.parse_xlsx,
    "text/csv": parsers.parse_csv,
    "text/plain": parsers.parse_txt,
}
IMAGES = {"image/jpeg", "image/png", "image/tiff"}


@dataclass
class Extraction:
    pages: list[Page]
    # Pages that needed OCR but got none (no provider configured).
    unread_pages: list[int]

    @property
    def has_text(self) -> bool:
        return any(page.blocks for page in self.pages)


def extract(data: bytes, mime_type: str, ocr: OcrProvider | None) -> Extraction:
    if mime_type in IMAGES:
        pages = parsers.image_pages()
    elif mime_type in NATIVE:
        pages = NATIVE[mime_type](data)
    else:
        raise PermanentError("unsupported_file", f"No parser for {mime_type}.")

    needing = [p.index for p in pages if p.needs_ocr]
    unread: list[int] = []
    if needing and ocr is not None:
        # Images go whole; for PDFs only the pages without a text layer.
        recognised = ocr.extract(data, mime_type, None if mime_type in IMAGES else needing)
        by_index = {p.index: p for p in recognised}
        for position, page in enumerate(pages):
            ocr_page = by_index.get(page.index)
            if page.needs_ocr and ocr_page is not None:
                ocr_page.label = ocr_page.label or page.label
                ocr_page.needs_ocr = False
                pages[position] = ocr_page
        unread = [p.index for p in pages if p.needs_ocr]
    elif needing:
        unread = needing

    for page in pages:
        page.assign_spans()
    return Extraction(pages=pages, unread_pages=unread)
