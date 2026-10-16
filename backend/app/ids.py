"""Opaque IDs with a type prefix, e.g. ``evd_3f9c...``.

They are random (not guessable) but access control never relies on that.
"""

import secrets


def new_id(prefix: str) -> str:
    return f"{prefix}_{secrets.token_hex(12)}"
