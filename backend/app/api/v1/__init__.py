"""All /v1 routes. Endpoint numbers match frontend/lib/core/api_endpoints.dart."""

from fastapi import APIRouter

from app.api.v1 import api_keys, cases, me

router = APIRouter()
router.include_router(me.router)
router.include_router(cases.router)
router.include_router(api_keys.router)
