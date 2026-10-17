"""Step 8: text extraction (parsers, OCR routing, spans)."""

from collections.abc import Sequence
from decimal import Decimal

import pytest

from app.pipeline import parsers
from app.pipeline.document import BBox, Block, Page
from app.pipeline.errors import PermanentError
from app.pipeline.extract import extract
from tests import samples

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


class FakeOcr:
    name = "fake_ocr"
    version = "test-1"

    def __init__(self) -> None:
        self.calls: list[Sequence[int] | None] = []

    def extract(self, data: bytes, mime_type: str, pages: Sequence[int] | None) -> list[Page]:
        self.calls.append(pages)
        wanted = list(pages) if pages else [1]
        return [
            Page(
                index=n,
                parser=self.name,
                parser_version=self.version,
                blocks=[
                    Block(
                        text=f"Scanned text on page {n}",
                        bbox=BBox(0.1, 0.1, 0.5, 0.15),
                        confidence=Decimal("0.97"),
                    )
                ],
            )
            for n in wanted
        ]


def _spans_match(page: Page) -> None:
    for block in page.blocks:
        assert page.text[block.char_start : block.char_end] == block.text


def test_pdf_text_layer_lines_with_positions() -> None:
    data = samples.text_pdf([["Purchase Order PO-1001", "Qty ordered: 100"], ["Received: 80"] * 2])
    result = extract(data, "application/pdf", ocr=None)
    assert result.unread_pages == []
    first = result.pages[0]
    assert [b.text for b in first.blocks] == ["Purchase Order PO-1001", "Qty ordered: 100"]
    assert first.text == "Purchase Order PO-1001\nQty ordered: 100"
    bbox = first.blocks[1].bbox
    assert bbox is not None and 0 <= bbox.x0 < bbox.x1 <= 1 and 0 <= bbox.y0 < bbox.y1 <= 1
    assert first.blocks[0].bbox is not None and first.blocks[0].bbox.y0 < bbox.y0  # top to bottom
    assert first.width == Decimal("595") and first.parser == "pdf_text"
    for page in result.pages:
        _spans_match(page)


def test_scanned_pdf_pages_go_to_ocr_only_where_needed() -> None:
    # Page 1 has text, pages 2 and 3 are blank (as a scan would be to a text parser).
    data = samples.text_pdf([["Purchase Order PO-1001", "Qty ordered: 100"], [], []])
    ocr = FakeOcr()
    result = extract(data, "application/pdf", ocr)
    assert ocr.calls == [[2, 3]]
    assert [p.parser for p in result.pages] == ["pdf_text", "fake_ocr", "fake_ocr"]
    assert result.pages[1].text == "Scanned text on page 2"
    assert result.unread_pages == []


def test_without_ocr_scanned_pages_are_reported_unread() -> None:
    result = extract(samples.pdf(2), "application/pdf", ocr=None)
    assert result.unread_pages == [1, 2]
    assert not result.has_text


def test_images_go_to_ocr_whole() -> None:
    ocr = FakeOcr()
    result = extract(samples.PNG, "image/png", ocr)
    assert ocr.calls == [None]
    assert result.pages[0].label == "Image"
    assert result.pages[0].blocks[0].confidence == Decimal("0.97")
    assert extract(samples.PNG, "image/png", None).unread_pages == [1]


def test_docx_paragraphs_and_table_rows() -> None:
    page = extract(samples.real_docx(), DOCX, None).pages[0]
    assert [(b.text, b.cell_ref) for b in page.blocks] == [
        ("Purchase Order PO-1001", None),
        ("Item | Qty ordered | Unit", "table 1, row 1"),
        ("Widget | 100 | units", "table 1, row 2"),
        ("Delivery by 2026-10-30", None),
    ]
    _spans_match(page)


def test_xlsx_one_page_per_sheet_with_cell_refs_and_clean_numbers() -> None:
    pages = extract(samples.real_xlsx(), XLSX, None).pages
    assert [p.label for p in pages] == ["Stock count", "Notes"]
    rows = [(b.text, b.cell_ref) for b in pages[0].blocks]
    assert rows[1] == ("Widget | 100 | 80 | 2026-10-16", "'Stock count'!A2:D2")  # 80.0 -> 80
    assert len(rows) == 3  # the empty row is skipped
    assert pages[1].blocks[0].cell_ref == "Notes!A1:B1"
    for page in pages:
        _spans_match(page)


def test_csv_and_txt() -> None:
    csv_page = extract(b"item;ordered\nWidget;100\n", "text/csv", None).pages[0]
    assert [(b.text, b.cell_ref) for b in csv_page.blocks] == [
        ("item | ordered", "row 1"),
        ("Widget | 100", "row 2"),
    ]
    txt_page = extract("Line one\n\nLíne two\n".encode("cp1252"), "text/plain", None).pages[0]
    assert [b.text for b in txt_page.blocks] == ["Line one", "Líne two"]


@pytest.mark.parametrize(
    ("data", "mime"),
    [
        (samples.docx(), DOCX),  # passes the upload check, but isn't a readable Word file
        (b"%PDF-1.4 broken", "application/pdf"),
        (samples.docx(), XLSX),
    ],
)
def test_unreadable_files_are_permanent_errors(data: bytes, mime: str) -> None:
    with pytest.raises(PermanentError) as error:
        extract(data, mime, None)
    assert error.value.code == "unreadable_file"


def test_too_many_rows_is_refused(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(parsers, "MAX_SPREADSHEET_ROWS", 2)
    with pytest.raises(PermanentError) as error:
        extract(b"a\nb\nc\n", "text/csv", None)
    assert error.value.code == "too_many_rows"


def test_short_text_pages_are_kept_not_sent_to_ocr() -> None:
    result = extract(samples.text_pdf([["Signed: J. Doe"]]), "application/pdf", FakeOcr())
    assert result.pages[0].parser == "pdf_text"
    assert result.pages[0].text == "Signed: J. Doe"
