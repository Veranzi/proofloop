"""Send notifications to people's registered devices with Firebase Cloud Messaging.

Runs in the worker (outbox event ``push.send``), never in a request. Tokens
that FCM reports as no longer valid are removed.
"""

import logging
from collections import defaultdict

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db.models import Device, Notification

logger = logging.getLogger("pruflo.push")


def fcm_send(tokens: list[str], title: str, body: str, link: str) -> list[str]:
    """Send one message to these tokens. Returns the tokens FCM says are dead.
    Replaced in tests."""
    from firebase_admin import messaging

    from app.auth.firebase import _firebase_app

    message = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(title=title, body=body or None),
        data={"link": link},
        webpush=messaging.WebpushConfig(
            fcm_options=messaging.WebpushFCMOptions(link=link)
            if link.startswith("https://")
            else None
        ),
    )
    result = messaging.send_each_for_multicast(message, app=_firebase_app())
    dead: list[str] = []
    for token, response in zip(tokens, result.responses, strict=True):
        if response.success:
            continue
        if isinstance(
            response.exception, messaging.UnregisteredError | messaging.SenderIdMismatchError
        ):
            dead.append(token)
        else:
            # Quota, auth or a malformed message: worth seeing, never the token itself.
            logger.warning("push to one device failed: %s", type(response.exception).__name__)
    return dead


def send_test(db: Session, user_id: str) -> tuple[int, int]:
    """Send a test push to every device of one person, now and in this process.
    Returns (devices tried, dead tokens removed). Raises if FCM can't be used."""
    settings = get_settings()
    tokens = list(db.scalars(select(Device.token).where(Device.user_id == user_id)))
    if not tokens:
        return 0, 0
    dead = fcm_send(
        tokens,
        "Pruflo test notification",
        "Push notifications are working on this device.",
        settings.public_app_url.rstrip("/") + "/#/dashboard",
    )
    if dead:
        db.execute(delete(Device).where(Device.token.in_(dead)))
        db.commit()
    return len(tokens), len(dead)


def send_push(db: Session, notification_ids: list[str]) -> int:
    settings = get_settings()
    notes = db.scalars(select(Notification).where(Notification.id.in_(notification_ids))).all()
    by_user: dict[str, list[Notification]] = defaultdict(list)
    for note in notes:
        by_user[note.user_id].append(note)
    if not by_user:
        return 0
    devices = db.scalars(select(Device).where(Device.user_id.in_(list(by_user)))).all()
    tokens: dict[str, list[str]] = defaultdict(list)
    for device in devices:
        tokens[device.user_id].append(device.token)
    sent = 0
    dead: list[str] = []
    for user_id, user_notes in by_user.items():
        if not tokens.get(user_id):
            continue
        for note in user_notes:
            app_link = settings.public_app_url.rstrip("/") + "/#" + note.link if note.link else ""
            try:
                dead += fcm_send(tokens[user_id], note.title, note.body, app_link)
                sent += 1
            except Exception as exc:  # FCM outage or misconfiguration: log, don't retry forever
                logger.warning("push failed: %s", type(exc).__name__)
    if dead:
        db.execute(delete(Device).where(Device.token.in_(dead)))
        db.commit()
    return sent
