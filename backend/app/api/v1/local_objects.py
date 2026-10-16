"""Stand-in for signed Cloud Storage URLs during local development and tests.

Mounted only when PRUFLO_ENV is local or test (see app.main). Every request
must carry a valid, unexpired HMAC signature from LocalStorage.
"""

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import FileResponse

from app.errors import ApiError, forbidden, not_found
from app.storage.backend import LocalStorage, Storage, get_storage

router = APIRouter(prefix="/_local/objects", include_in_schema=False)


def _local(storage: Storage) -> LocalStorage:
    if not isinstance(storage, LocalStorage):
        raise not_found()
    return storage


@router.put("/{key:path}", status_code=200)
async def put_object(
    key: str,
    request: Request,
    expires: int,
    sig: str,
    max: int,
    ct: str,
    storage: Storage = Depends(get_storage),
) -> Response:
    local = _local(storage)
    if not local.verify("PUT", key, expires, sig, f"{ct}\n{max}"):
        raise forbidden("Invalid or expired upload link.")
    if request.headers.get("content-type", "").split(";")[0] != ct:
        raise forbidden("Content-Type must match the signed upload.")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > max:
            raise ApiError(413, "file_too_large", "The file is larger than allowed.")
    local.write(key, bytes(body), ct)
    return Response(status_code=200)


@router.get("/{key:path}")
def get_object(
    key: str, expires: int, sig: str, storage: Storage = Depends(get_storage)
) -> FileResponse:
    local = _local(storage)
    if not local.verify("GET", key, expires, sig):
        raise forbidden("Invalid or expired link.")
    info = local.stat(key)
    if info is None:
        raise not_found()
    return FileResponse(local.path(key), media_type=info.content_type)
