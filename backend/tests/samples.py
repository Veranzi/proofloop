"""Tiny synthetic files of each accepted type, built in memory."""

import io
import zipfile

from pypdf import PdfWriter


def pdf(pages: int = 1) -> bytes:
    writer = PdfWriter()
    for _ in range(pages):
        writer.add_blank_page(width=595, height=842)
    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()


def _office(main_part: str, extra: dict[str, str] | None = None) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr(main_part, "<doc/>")
        for name, content in (extra or {}).items():
            archive.writestr(name, content)
    return out.getvalue()


def docx() -> bytes:
    return _office("word/document.xml")


def xlsx() -> bytes:
    return _office("xl/workbook.xml")


def docm() -> bytes:
    return _office("word/document.xml", {"word/vbaProject.bin": "macro"})


PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
CSV = b"item,ordered,delivered\nWidget,100,80\n"
