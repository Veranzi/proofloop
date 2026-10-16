"""Who can do what (Docs/backend_plan.md, Step 0, "Roles and permissions")."""

from enum import StrEnum

from app.enums import ApiKeyScope, Role


class Permission(StrEnum):
    VIEW_CASES = "view_cases"  # cases, evidence, claims, findings, timeline
    EDIT_CASES = "edit_cases"  # create and update cases
    UPLOAD_EVIDENCE = "upload_evidence"
    DECIDE = "decide"  # record a review decision (endpoint 15)
    EXPORT = "export"  # PDF reports and JSON/CSV export (17-19, 50)
    ADMIN = "admin"  # everything under /v1/admin


ROLE_PERMISSIONS: dict[Role, frozenset[Permission]] = {
    Role.INVESTIGATOR: frozenset(
        {
            Permission.VIEW_CASES,
            Permission.EDIT_CASES,
            Permission.UPLOAD_EVIDENCE,
            Permission.EXPORT,
        }
    ),
    Role.REVIEWER: frozenset({Permission.VIEW_CASES, Permission.DECIDE, Permission.EXPORT}),
    Role.ADMIN: frozenset(Permission),
    Role.VIEWER: frozenset({Permission.VIEW_CASES}),
}

# What each API key scope allows. DECIDE and ADMIN are deliberately absent:
# only a signed-in person can decide, and keys never reach /v1/admin.
SCOPE_PERMISSIONS: dict[ApiKeyScope, frozenset[Permission]] = {
    ApiKeyScope.CASES_READ: frozenset({Permission.VIEW_CASES}),
    ApiKeyScope.CASES_WRITE: frozenset({Permission.VIEW_CASES, Permission.EDIT_CASES}),
    ApiKeyScope.EVIDENCE_WRITE: frozenset({Permission.UPLOAD_EVIDENCE}),
    ApiKeyScope.FINDINGS_READ: frozenset({Permission.VIEW_CASES, Permission.EXPORT}),
    ApiKeyScope.REPORTS_READ: frozenset({Permission.EXPORT}),
}

PEOPLE_ONLY = frozenset({Permission.DECIDE, Permission.ADMIN})


def permissions_for_scopes(scopes: list[str]) -> frozenset[Permission]:
    granted: set[Permission] = set()
    for scope in scopes:
        granted |= SCOPE_PERMISSIONS.get(ApiKeyScope(scope), frozenset())
    return frozenset(granted - PEOPLE_ONLY)
