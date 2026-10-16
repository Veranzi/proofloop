"""Render a case report as a PDF with fpdf2 (pure Python; no browser or system
libraries beyond a Unicode font).

Report types:
- executive: one page of counts and the findings that still need a decision.
- summary: the case, evidence list and a line per finding.
- detailed: every chosen section in full, with quotes and review notes.
"""

from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fpdf import FPDF
from fpdf.enums import XPos, YPos

from app.db.models import AuditEvent, Case, EvidenceFile, User

FONT_DIR = Path("/usr/share/fonts/truetype/dejavu")  # fonts-dejavu-core on Debian
DISCLAIMER = (
    "Findings are produced by deterministic rules from values extracted from the evidence. "
    "They are not conclusions: each one needs human interpretation, and only decisions "
    "recorded by a named reviewer are final."
)


class _Pdf(FPDF):
    def __init__(self, footer_text: str) -> None:
        super().__init__(format="A4")
        self.footer_text = footer_text
        regular, bold = FONT_DIR / "DejaVuSans.ttf", FONT_DIR / "DejaVuSans-Bold.ttf"
        if regular.exists() and bold.exists():
            self.add_font("Body", "", str(regular))
            self.add_font("Body", "B", str(bold))
            self.body_font = "Body"
            self.unicode_ok = True
        else:  # Latin-1 core font; other characters are replaced
            self.body_font = "Helvetica"
            self.unicode_ok = False
        self.set_auto_page_break(auto=True, margin=18)
        self.set_margins(18, 18, 18)

    def text_safe(self, text: Any) -> str:
        value = "" if text is None else str(text)
        return value if self.unicode_ok else value.encode("latin-1", "replace").decode("latin-1")

    def footer(self) -> None:
        self.set_y(-12)
        self.set_font(self.body_font, "", 8)
        self.set_text_color(110)
        self.cell(0, 6, self.text_safe(f"{self.footer_text}  ·  page {self.page_no()}"), align="C")

    def heading(self, text: str, size: float = 13) -> None:
        self.ln(3)
        self.set_font(self.body_font, "B", size)
        self.set_text_color(20)
        self.multi_cell(0, 7, self.text_safe(text), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(1)

    def para(self, text: str, size: float = 10, bold: bool = False, color: int = 40) -> None:
        self.set_font(self.body_font, "B" if bold else "", size)
        self.set_text_color(color)
        self.multi_cell(0, 5.2, self.text_safe(text), new_x=XPos.LMARGIN, new_y=YPos.NEXT)

    def row(self, label: str, value: Any) -> None:
        self.set_font(self.body_font, "B", 9.5)
        self.set_text_color(70)
        self.cell(42, 5.5, self.text_safe(label))
        self.set_font(self.body_font, "", 9.5)
        self.set_text_color(30)
        self.multi_cell(0, 5.5, self.text_safe(value), new_x=XPos.LMARGIN, new_y=YPos.NEXT)


def _value(v: dict[str, Any] | None) -> str:
    if not v:
        return "-"
    return f"{v.get('value', '-')} {v.get('unit') or ''}".strip()


def render(
    case: Case,
    options: dict[str, Any],
    evidence: list[EvidenceFile],
    export: dict[str, Any],
    timeline: list[tuple[AuditEvent, User | None]],
) -> bytes:
    report_type = options.get("type", "detailed")
    sections = set(options.get("sections") or ["evidence", "timeline", "findings"])
    generated = datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC")
    pdf = _Pdf(f"PruFlo · {case.reference} · generated {generated}")
    pdf.add_page()

    pdf.para("PruFlo case report", size=9, color=110)
    pdf.heading(f"{case.reference} · {case.title}", size=17)
    pdf.row("Report type", report_type.capitalize())
    pdf.row("Status", case.status.replace("_", " "))
    pdf.row("Priority", case.priority)
    if case.category:
        pdf.row("Category", case.category)
    pdf.row("Generated", generated)
    if case.description:
        pdf.ln(2)
        pdf.para(case.description)

    findings = export["findings"]
    by_status = Counter(f["review"]["status"] for f in findings)
    pdf.heading("At a glance")
    pdf.row("Evidence files", len(evidence))
    pdf.row("Findings", len(findings))
    pdf.row("Approved", by_status.get("approve", 0))
    pdf.row("Rejected", by_status.get("reject", 0))
    pdf.row("Pending review", by_status.get("pending", 0))
    pdf.ln(2)
    pdf.para(DISCLAIMER, size=8.5, color=90)

    detailed = report_type == "detailed"
    if report_type != "executive" and "evidence" in sections:
        pdf.heading("Evidence")
        if not evidence:
            pdf.para("No evidence has been uploaded.")
        for e in evidence:
            pages = f", {e.page_count} pages" if e.page_count else ""
            pdf.para(f"{e.original_filename}", bold=True, size=9.5)
            line = f"{e.status.replace('_', ' ')}{pages}"
            if detailed and e.sha256:
                line += f" · SHA-256 {e.sha256[:16]}…"
            pdf.para(line, size=8.5, color=90)

    if "findings" in sections or report_type == "executive":
        pdf.heading("Findings")
        shown = (
            [f for f in findings if f["review"]["status"] == "pending"]
            if report_type == "executive"
            else findings
        )
        if not shown:
            pdf.para("No findings." if not findings else "No findings are waiting for review.")
        for number, f in enumerate(shown, start=1):
            pdf.para(
                f"{number}. {f['type'].replace('_', ' ').capitalize()} ({f['severity']} severity)",
                bold=True,
                size=10,
            )
            pdf.row("Expected", _value(f.get("expected")))
            pdf.row("Observed", _value(f.get("observed")))
            pdf.row("Difference", _value(f.get("difference")))
            review = f["review"]
            decided = f" by {review['by']}" if review.get("by") else ""
            pdf.row("Review", f"{review['status']}{decided}")
            if detailed:
                if review.get("note"):
                    pdf.row("Reviewer note", review["note"])
                if f.get("explanation"):
                    label = (
                        "Explanation (machine-generated)"
                        if f.get("explanation_source") == "machine_generated"
                        else "Explanation"
                    )
                    pdf.row(label, f["explanation"])
                for e in f["evidence"]:
                    pdf.row(
                        "Source",
                        f"{e['file_name']} p{e['page']}: “{e['quote']}” ({e['grounding']})",
                    )
            pdf.ln(1.5)

    if report_type != "executive" and "timeline" in sections:
        pdf.heading("Timeline")
        if not timeline:
            pdf.para("Nothing has happened on this case yet.")
        for event, user in timeline:
            who = user.name if user else ("an API key" if event.actor_api_key_id else "system")
            when = event.created_at.strftime("%Y-%m-%d %H:%M")
            title = event.details.get("title") or event.action.replace(".", " ").replace("_", " ")
            pdf.para(f"{when}  ·  {title}  ·  {who}", size=8.5, color=60)

    if "recommendations" in sections and report_type != "executive":
        pdf.heading("Next steps")
        pending = [f for f in findings if f["review"]["status"] == "pending"]
        failed = [e for e in evidence if e.status in ("failed_terminal", "needs_review")]
        steps = []
        if pending:
            steps.append(f"Review the {len(pending)} finding(s) still pending.")
        if failed:
            names = ", ".join(e.original_filename for e in failed[:5])
            steps.append(f"Check the evidence that couldn't be fully read: {names}.")
        if not steps:
            steps.append("Nothing outstanding: every finding has a decision.")
        for step in steps:
            pdf.para(f"• {step}")

    return bytes(pdf.output())
