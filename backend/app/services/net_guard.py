"""Server-side request forgery (SSRF) protection for outgoing webhooks.

Only HTTPS URLs whose host resolves to public addresses are allowed. The
check runs when a URL is saved and again before every delivery, because DNS
can change in between.
"""

import ipaddress
import socket
from urllib.parse import urlsplit

BLOCKED_HOSTS = {"localhost", "metadata.google.internal", "metadata"}


class UnsafeUrl(ValueError):
    pass


def resolve(host: str) -> list[str]:
    """All addresses ``host`` resolves to. Replaced in tests."""
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise UnsafeUrl(f"{host} couldn't be resolved.") from exc
    return sorted({str(info[4][0]) for info in infos})


def check_url(url: str) -> str:
    """Return the URL if it's safe to call, otherwise raise UnsafeUrl."""
    parts = urlsplit(url.strip())
    if parts.scheme != "https":
        raise UnsafeUrl("The URL must use https.")
    if parts.username or parts.password:
        raise UnsafeUrl("The URL can't contain a username or password.")
    host = (parts.hostname or "").rstrip(".").lower()
    if not host or host in BLOCKED_HOSTS or host.endswith(".internal") or host.endswith(".local"):
        raise UnsafeUrl("That host isn't allowed.")
    addresses = [host] if _is_ip(host) else resolve(host)
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if not ip.is_global or ip.is_multicast:
            raise UnsafeUrl("The URL points to a private or reserved address.")
    return url.strip()


def _is_ip(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True
