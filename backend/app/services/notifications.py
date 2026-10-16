"""In-app notifications, optionally pushed to people's devices.

Each person chooses which kinds they get (``User.notification_prefs``).
Notifications are written in the same transaction as the change that
caused them; push delivery goes through the outbox to the worker.
"""

from collections import Counter
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.db.models import Case, CaseMember, Finding, Membership, Notification, User
from app.enums import CaseStatus, NotificationKind, ReviewDecision, Role
from app.ids import new_id
from app.services import outbox

DEFAULT_PREFS: dict[str, bool] = {
    NotificationKind.EVIDENCE_PROCESSED: True,
    NotificationKind.CASE_ASSIGNED: True,
    NotificationKind.CASE_IN_REVIEW: True,
    NotificationKind.REPORT_READY: True,
    NotificationKind.WEEKLY_SUMMARY: False,
    "push": True,
}
KEEP_FOR = timedelta(days=90)
SEND_PUSH = "push.send"


def preferences(user: User) -> dict[str, bool]:
    return {
        key: bool(user.notification_prefs.get(key, default))
        for key, default in DEFAULT_PREFS.items()
    }


def case_link(case: Case) -> str:
    return f"/cases/{case.id}"


def notify(
    db: Session,
    tenant_id: str,
    user_ids: Iterable[str | None],
    kind: NotificationKind,
    title: str,
    body: str = "",
    *,
    case: Case | None = None,
    link: str | None = None,
    exclude: str | None = None,
    at: datetime | None = None,
) -> list[Notification]:
    """Create notifications for the people who want this kind. Doesn't commit."""
    wanted = {u for u in user_ids if u and u != exclude}
    if not wanted:
        return []
    users = db.scalars(select(User).where(User.id.in_(wanted), User.active.is_(True))).all()
    created: list[Notification] = []
    push_ids: list[str] = []
    for user in users:
        prefs = preferences(user)
        if not prefs[kind]:
            continue
        note = Notification(
            id=new_id("ntf"),
            tenant_id=tenant_id,
            user_id=user.id,
            kind=kind,
            title=title[:200],
            body=body[:500],
            case_id=case.id if case else None,
            link=(link if link is not None else (case_link(case) if case else ""))[:300],
        )
        if at is not None:
            note.created_at = at
        db.add(note)
        created.append(note)
        if prefs["push"]:
            push_ids.append(note.id)
    if push_ids:
        # The worker looks up each person's registered devices after commit.
        db.flush()
        outbox.emit(db, tenant_id, "processing", SEND_PUSH, {"notification_ids": push_ids})
    return created


def reviewers_of(db: Session, case: Case) -> list[str]:
    """Case members who can decide on findings (reviewers and admins)."""
    return list(
        db.scalars(
            select(CaseMember.user_id)
            .join(
                Membership,
                (Membership.user_id == CaseMember.user_id)
                & (Membership.tenant_id == case.tenant_id),
            )
            .where(CaseMember.case_id == case.id, Membership.role.in_([Role.REVIEWER, Role.ADMIN]))
        )
    )


def weekly_summary(db: Session, now: datetime | None = None) -> int:
    """Monday summary for everyone who switched it on. Safe to run more than once a week."""
    now = now or datetime.now(UTC)
    week_start = (now - timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    sent = 0
    rows = db.execute(
        select(User, Membership)
        .join(Membership, Membership.user_id == User.id)
        .where(User.active.is_(True))
    ).all()
    for user, membership in rows:
        if not preferences(user)[NotificationKind.WEEKLY_SUMMARY]:
            continue
        already = db.scalar(
            select(func.count())
            .select_from(Notification)
            .where(
                Notification.user_id == user.id,
                Notification.tenant_id == membership.tenant_id,
                Notification.kind == NotificationKind.WEEKLY_SUMMARY,
                Notification.created_at >= week_start,
                Notification.created_at < week_start + timedelta(days=7),
            )
        )
        if already:
            continue
        cases = select(Case.id, Case.status).where(Case.tenant_id == membership.tenant_id)
        if membership.role != Role.ADMIN:
            cases = cases.join(
                CaseMember, (CaseMember.case_id == Case.id) & (CaseMember.user_id == user.id)
            )
        visible = db.execute(cases).all()
        statuses = Counter(status for _, status in visible)
        pending = (
            db.scalar(
                select(func.count())
                .select_from(Finding)
                .where(
                    Finding.case_id.in_([cid for cid, _ in visible]),
                    Finding.review_status == ReviewDecision.PENDING,
                )
            )
            if visible
            else 0
        )
        body = (
            f"{statuses.get(CaseStatus.IN_REVIEW, 0)} in review, "
            f"{statuses.get(CaseStatus.AWAITING_EVIDENCE, 0)} awaiting evidence, "
            f"{statuses.get(CaseStatus.COMPLETED, 0)} completed. "
            f"{pending} finding(s) waiting for a decision."
        )
        # Stamped with this run's time, so "already sent this week" holds even if
        # the scheduled job runs late or twice.
        sent += len(
            notify(
                db,
                membership.tenant_id,
                [user.id],
                NotificationKind.WEEKLY_SUMMARY,
                "Your week in Pruflo",
                body,
                link="/cases",
                at=now,
            )
        )
    db.commit()
    return sent


def purge_old(db: Session, now: datetime | None = None) -> int:
    now = now or datetime.now(UTC)
    removed = db.execute(
        delete(Notification).where(Notification.created_at < now - KEEP_FOR)
    ).rowcount
    db.commit()
    return int(removed or 0)
