"""All /v1 routes. Endpoint numbers match frontend/lib/core/api_endpoints.dart."""

from fastapi import APIRouter

from app.api.v1 import admin, api_keys, cases, evidence, findings, me, reports

router = APIRouter()
router.include_router(me.router)
router.include_router(cases.router)
router.include_router(evidence.router)
router.include_router(findings.router)
router.include_router(reports.router)
router.include_router(api_keys.router)
router.include_router(admin.router)
