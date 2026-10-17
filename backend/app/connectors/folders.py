"""Google Drive and SharePoint folders, polled with the admin's OAuth grant.

Both work the same way once the provider-specific listing is done:

- Each subfolder of the connected folder is one case (a case reference such
  as PL-001 in its name picks that existing case). Everything inside the
  subfolder, at any depth, goes to that case.
- A file directly in the connected folder opens its own case, unless its
  name mentions a case reference.
- A file is imported once per version: a new version of the same file is
  added as new evidence.

Google Docs and Sheets are exported as PDF and XLSX; other Google-native
files are skipped. At most ``PER_SYNC`` files are fetched per run; the rest
follow on the next one.
"""

import re
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from functools import partial
from typing import Any
from urllib.parse import parse_qs, quote, unquote, urlsplit

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import MAX_FILE_BYTES
from app.connectors import base, oauth
from app.connectors.base import (
    ConnectorFailed,
    case_for,
    credentials,
    store_credentials,
)
from app.db.models import Connector, EvidenceFile
from app.enums import ConnectorKind, EvidenceSource
from app.services.evidence import UploadRejected, import_file
from app.storage import file_types
from app.storage.backend import Storage

PER_SYNC = 100
MAX_DEPTH = 5
DRIVE = "https://www.googleapis.com/drive/v3"
GRAPH = "https://graph.microsoft.com/v1.0"
GOOGLE_FOLDER = "application/vnd.google-apps.folder"
GOOGLE_EXPORTS = {
    "application/vnd.google-apps.document": ("application/pdf", ".pdf"),
    "application/vnd.google-apps.spreadsheet": (
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".xlsx",
    ),
}


@dataclass
class RemoteFile:
    id: str
    name: str
    size: int | None
    version: str
    group: tuple[str, str] | None  # (subfolder id, subfolder name); None at the top
    download: Callable[[], bytes]


class Api:
    """GET requests with a bearer token. Errors become messages a person can read."""

    def __init__(self, token: str) -> None:
        self.headers = {"Authorization": f"Bearer {token}"}

    def get(self, url: str, **params: Any) -> httpx.Response:
        try:
            with base.http_client() as client:
                response = client.get(
                    url, params=params or None, headers=self.headers, follow_redirects=True
                )
        except httpx.HTTPError as exc:
            raise ConnectorFailed("The folder couldn't be reached. Try again later.") from exc
        if response.status_code in (401, 403):
            raise ConnectorFailed("Access to the folder was refused. Connect it again.")
        if response.status_code == 404:
            raise ConnectorFailed("The folder wasn't found. It may have been moved or deleted.")
        if response.status_code != 200:
            raise ConnectorFailed(f"The folder service answered with HTTP {response.status_code}.")
        return response

    def content(self, url: str, **params: Any) -> bytes:
        return self.get(url, **params).content

    def json(self, url: str, **params: Any) -> dict[str, Any]:
        data: dict[str, Any] = self.get(url, **params).json()
        return data


# Google Drive ---------------------------------------------------------------


def drive_folder_id(link: str) -> str:
    found = _drive_folder_id(link.strip())
    # It goes into a Drive query ('<id>' in parents), so only ID characters.
    if not re.fullmatch(r"[A-Za-z0-9_-]{10,200}", found):
        raise ConnectorFailed("That link isn't a Google Drive folder.")
    return found


def _drive_folder_id(link: str) -> str:
    parts = urlsplit(link)
    if not parts.scheme:
        return link  # a bare folder ID
    if parts.hostname != "drive.google.com":
        raise ConnectorFailed("Paste a Google Drive folder link (https://drive.google.com/...).")
    segments = [s for s in parts.path.split("/") if s]
    if "folders" in segments and segments.index("folders") + 1 < len(segments):
        return segments[segments.index("folders") + 1]
    if ids := parse_qs(parts.query).get("id"):
        return ids[0]
    raise ConnectorFailed("That link isn't a Google Drive folder.")


def drive_resolve(api: Api, link: str) -> tuple[dict[str, str], str]:
    folder_id = drive_folder_id(link)
    meta = api.json(
        f"{DRIVE}/files/{quote(folder_id)}", fields="id,name,mimeType", supportsAllDrives="true"
    )
    if meta.get("mimeType") != GOOGLE_FOLDER:
        raise ConnectorFailed("That link is a file, not a folder.")
    return {"folder_id": meta["id"]}, str(meta.get("name", ""))


def _drive_children(api: Api, folder_id: str) -> Iterator[dict[str, Any]]:
    token: str | None = None
    while True:
        params = {
            "q": f"'{folder_id}' in parents and trashed = false",
            "fields": "nextPageToken,files(id,name,mimeType,size,md5Checksum,modifiedTime)",
            "pageSize": "200",
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        }
        if token:
            params["pageToken"] = token
        page = api.json(f"{DRIVE}/files", **params)
        yield from page.get("files", [])
        token = page.get("nextPageToken")
        if not token:
            return


def drive_files(api: Api, ref: dict[str, str]) -> Iterator[RemoteFile]:
    def walk(folder_id: str, group: tuple[str, str] | None, depth: int) -> Iterator[RemoteFile]:
        for item in _drive_children(api, folder_id):
            mime = item.get("mimeType", "")
            if mime == GOOGLE_FOLDER:
                if depth < MAX_DEPTH:
                    yield from walk(item["id"], group or (item["id"], item["name"]), depth + 1)
                continue
            file_id, name = item["id"], item["name"]
            if mime in GOOGLE_EXPORTS:
                export, extension = GOOGLE_EXPORTS[mime]
                yield RemoteFile(
                    file_id,
                    name + extension,
                    None,
                    item.get("modifiedTime", ""),
                    group,
                    partial(api.content, f"{DRIVE}/files/{quote(file_id)}/export", mimeType=export),
                )
            elif not mime.startswith("application/vnd.google-apps."):
                yield RemoteFile(
                    file_id,
                    name,
                    int(item["size"]) if item.get("size") else None,
                    item.get("md5Checksum") or item.get("modifiedTime", ""),
                    group,
                    partial(
                        api.content,
                        f"{DRIVE}/files/{quote(file_id)}",
                        alt="media",
                        supportsAllDrives="true",
                    ),
                )

    yield from walk(ref["folder_id"], None, 0)


# SharePoint (Microsoft Graph) -------------------------------------------------


def _graph_pages(api: Api, url: str) -> Iterator[dict[str, Any]]:
    next_url: str | None = url
    while next_url:
        if not next_url.startswith(GRAPH + "/"):
            raise ConnectorFailed("SharePoint sent an unexpected link.")
        page = api.json(next_url)
        yield from page.get("value", [])
        next_url = page.get("@odata.nextLink")


def sharepoint_resolve(api: Api, link: str) -> tuple[dict[str, str], str]:
    parts = urlsplit(link.strip())
    host = parts.hostname or ""
    if parts.scheme != "https" or not host.endswith(".sharepoint.com"):
        raise ConnectorFailed(
            "Paste a SharePoint library link (https://<company>.sharepoint.com/...)."
        )
    path = unquote(parts.path).strip("/")
    segments = path.split("/") if path else []
    if len(segments) >= 2 and segments[0] in ("sites", "teams"):
        site = api.json(f"{GRAPH}/sites/{host}:/{quote('/'.join(segments[:2]))}")
    else:
        site = api.json(f"{GRAPH}/sites/{host}")
    target = f"https://{host}/{path}".rstrip("/")
    best: tuple[dict[str, Any], str] | None = None
    for drive in _graph_pages(api, f"{GRAPH}/sites/{site['id']}/drives?$select=id,name,webUrl"):
        web = unquote(str(drive.get("webUrl", ""))).rstrip("/")
        if (target == web or target.startswith(web + "/")) and (
            best is None or len(web) > len(best[1])
        ):
            best = (drive, web)
    if best is None:
        raise ConnectorFailed("That link isn't a document library in this SharePoint site.")
    drive, web = best
    rest = target[len(web) :].strip("/")
    item_url = f"{GRAPH}/drives/{drive['id']}/root" + (f":/{quote(rest)}" if rest else "")
    item = api.json(item_url)
    if "folder" not in item:
        raise ConnectorFailed("That link is a file, not a folder.")
    return {"drive_id": drive["id"], "item_id": item["id"]}, str(item.get("name") or drive["name"])


def sharepoint_files(api: Api, ref: dict[str, str]) -> Iterator[RemoteFile]:
    drive = ref["drive_id"]

    def walk(item_id: str, group: tuple[str, str] | None, depth: int) -> Iterator[RemoteFile]:
        url = (
            f"{GRAPH}/drives/{drive}/items/{item_id}/children"
            "?$select=id,name,size,file,folder,lastModifiedDateTime,eTag&$top=200"
        )
        for item in _graph_pages(api, url):
            if "folder" in item:
                if depth < MAX_DEPTH:
                    yield from walk(item["id"], group or (item["id"], item["name"]), depth + 1)
                continue
            if "file" not in item:
                continue
            hashes = item["file"].get("hashes") or {}
            yield RemoteFile(
                item["id"],
                item["name"],
                item.get("size"),
                hashes.get("quickXorHash")
                or item.get("eTag")
                or item.get("lastModifiedDateTime", ""),
                group,
                partial(api.content, f"{GRAPH}/drives/{drive}/items/{item['id']}/content"),
            )

    yield from walk(ref["item_id"], None, 0)


# Shared -----------------------------------------------------------------------

RESOLVERS = {
    ConnectorKind.GOOGLE_DRIVE: drive_resolve,
    ConnectorKind.SHAREPOINT: sharepoint_resolve,
}
LISTERS = {ConnectorKind.GOOGLE_DRIVE: drive_files, ConnectorKind.SHAREPOINT: sharepoint_files}


def finish_connect(connector: Connector, refresh_token: str, token: str) -> str:
    """After consent: check the folder and keep the grant. Returns the folder's name."""
    kind = ConnectorKind(connector.kind)
    ref, name = RESOLVERS[kind](Api(token), str(connector.state.get("folder_link", "")))
    store_credentials(connector, {"refresh_token": refresh_token})
    connector.state = {**connector.state, "folder": ref}
    return name


def sync(db: Session, storage: Storage, connector: Connector) -> int:
    kind = ConnectorKind(connector.kind)
    creds = credentials(connector)
    token, rotated = oauth.access_token(kind, creds["refresh_token"])
    if rotated and rotated != creds["refresh_token"]:
        store_credentials(connector, {**creds, "refresh_token": rotated})
        db.commit()
    source = EvidenceSource(kind.value)
    seen = set(
        db.scalars(
            select(EvidenceFile.source_ref).where(
                EvidenceFile.tenant_id == connector.tenant_id, EvidenceFile.source == source
            )
        )
    )
    imported = fetched = 0
    for remote in LISTERS[kind](Api(token), connector.state["folder"]):
        ref = f"{remote.id}:{remote.version}"
        if ref in seen or file_types.extension_of(remote.name) not in file_types.FILE_TYPES:
            continue
        if fetched >= PER_SYNC:
            break
        if remote.group is None:
            case = case_for(db, connector, f"file:{remote.id}", remote.name)
        else:
            case = case_for(db, connector, f"folder:{remote.group[0]}", remote.group[1])
        too_big = remote.size is not None and remote.size > MAX_FILE_BYTES
        data = None if too_big else remote.download()
        fetched += 1
        try:
            if import_file(
                db,
                storage,
                case,
                file_name=remote.name,
                data=data,
                size=remote.size,
                source=source,
                source_ref=ref,
                uploaded_by=connector.connected_by,
            ):
                imported += 1
        except UploadRejected:  # pragma: no cover - the extension was checked above
            db.commit()
    return imported
