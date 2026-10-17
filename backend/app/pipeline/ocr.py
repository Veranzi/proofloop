"""OCR behind a small interface (Docs/Integrations_API_Contract.md §5).

Only ``google_document_ai`` exists now. Other providers can be added
without touching grounding, rules or review.
"""

from collections.abc import Sequence
from decimal import Decimal
from functools import lru_cache
from typing import Any, Protocol

from app.config import get_settings
from app.pipeline.document import BBox, Block, Page
from app.pipeline.errors import PermanentError, TransientError

# Document AI online (synchronous) requests accept at most 15 pages.
ONLINE_PAGE_LIMIT = 15


class OcrProvider(Protocol):
    name: str
    version: str  # processor ID / version, recorded on every page

    def extract(self, data: bytes, mime_type: str, pages: Sequence[int] | None) -> list[Page]:
        """OCR the given 1-based pages (all pages when None)."""
        ...


def _bbox(vertices: Any) -> BBox | None:
    points = [(float(v.x), float(v.y)) for v in vertices]
    if not points:
        return None
    xs, ys = zip(*points, strict=True)
    return BBox(min(xs), min(ys), max(xs), max(ys))


def _anchor_text(full_text: str, layout: Any) -> str:
    return "".join(
        full_text[int(seg.start_index) : int(seg.end_index)]
        for seg in layout.text_anchor.text_segments
    ).strip()


class DocumentAiOcr:
    name = "google_document_ai"

    def __init__(self, project: str, location: str, processor_id: str) -> None:
        from google.api_core.client_options import ClientOptions
        from google.cloud import documentai

        self._documentai = documentai
        self._client = documentai.DocumentProcessorServiceClient(
            client_options=ClientOptions(api_endpoint=f"{location}-documentai.googleapis.com")
        )
        self._processor = self._client.processor_path(project, location, processor_id)
        self.version = f"{location}/{processor_id}"

    def extract(self, data: bytes, mime_type: str, pages: Sequence[int] | None) -> list[Page]:
        if not pages:
            return self._process(data, mime_type, [])
        wanted = list(pages)
        out: list[Page] = []
        # Online requests take at most 15 pages, so ask for them in chunks.
        for start in range(0, len(wanted), ONLINE_PAGE_LIMIT):
            out.extend(self._process(data, mime_type, wanted[start : start + ONLINE_PAGE_LIMIT]))
        return out

    def _process(self, data: bytes, mime_type: str, pages: list[int]) -> list[Page]:
        from google.api_core import exceptions as gexc

        documentai = self._documentai
        options = None
        if pages:
            options = documentai.ProcessOptions(
                individual_page_selector=documentai.ProcessOptions.IndividualPageSelector(
                    pages=pages
                )
            )
        request = documentai.ProcessRequest(
            name=self._processor,
            raw_document=documentai.RawDocument(content=data, mime_type=mime_type),
            process_options=options,
        )
        try:
            document = self._client.process_document(request=request, timeout=120).document
        except (
            gexc.ServiceUnavailable,
            gexc.DeadlineExceeded,
            gexc.TooManyRequests,
            gexc.InternalServerError,
        ) as exc:
            raise TransientError("ocr_unavailable", str(exc)) from exc
        except gexc.InvalidArgument as exc:
            raise PermanentError(
                "ocr_rejected", "The OCR service couldn't read this file."
            ) from exc

        result: list[Page] = []
        for ocr_page in document.pages:
            page = Page(
                index=int(ocr_page.page_number),
                width=Decimal(str(ocr_page.dimension.width)) if ocr_page.dimension else None,
                height=Decimal(str(ocr_page.dimension.height)) if ocr_page.dimension else None,
                parser=self.name,
                parser_version=self.version,
            )
            for line in ocr_page.lines:
                text = _anchor_text(document.text, line.layout)
                if text:
                    page.blocks.append(
                        Block(
                            text=text,
                            bbox=_bbox(line.layout.bounding_poly.normalized_vertices),
                            confidence=Decimal(str(round(line.layout.confidence, 4))),
                        )
                    )
            result.append(page)
        return result


@lru_cache
def get_ocr_provider() -> OcrProvider | None:
    """None when OCR isn't configured (local development); scans then need review."""
    settings = get_settings()
    if not settings.documentai_processor_id:
        return None
    if not settings.documentai_location:
        raise RuntimeError("Set PRUFLO_DOCUMENTAI_LOCATION along with the processor ID.")
    return DocumentAiOcr(
        settings.gcp_project, settings.documentai_location, settings.documentai_processor_id
    )
