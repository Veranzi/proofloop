"""Small builders for test data. Each returns committed rows (savepoints in tests)."""

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import api_keys
from app.db.models import (
    ApiKey,
    Case,
    CaseMember,
    EvidenceFile,
    ExtractedClaim,
    Finding,
    Membership,
    Rule,
    Tenant,
    User,
)
from app.enums import EvidenceStatus, ReviewDecision, Role, RuleTemplate
from app.ids import new_id


@dataclass
class Person:
    user: User
    tenant: Tenant
    role: Role

    @property
    def headers(self) -> dict[str, str]:
        assert self.user.firebase_uid, "invited users have no token yet"
        return {"Authorization": f"Bearer dev:{self.user.firebase_uid}:{self.user.email}"}


class Factory:
    def __init__(self, db: Session) -> None:
        self.db = db

    def tenant(self, name: str = "Acme") -> Tenant:
        tenant = Tenant(id=new_id("ten"), name=name)
        self.db.add(tenant)
        self.db.commit()
        return tenant

    def person(
        self,
        role: Role = Role.INVESTIGATOR,
        tenant: Tenant | None = None,
        *,
        name: str = "Test Person",
        invited_only: bool = False,
        active: bool = True,
    ) -> Person:
        tenant = tenant or self.tenant()
        uid = new_id("fb")
        user = User(
            id=new_id("u"),
            firebase_uid=None if invited_only else uid,
            email=f"{uid}@example.com",
            name=name,
            active=active,
        )
        self.db.add(user)
        self.db.flush()
        self.db.add(Membership(id=new_id("mem"), tenant_id=tenant.id, user_id=user.id, role=role))
        self.db.commit()
        return Person(user=user, tenant=tenant, role=role)

    def case(self, tenant: Tenant, *members: Person, title: str = "Fraud Investigation") -> Case:
        tenant.next_case_number = (tenant.next_case_number or 1) + 1
        case = Case(
            id=new_id("case"),
            tenant_id=tenant.id,
            reference=f"PL-{tenant.next_case_number - 1:03d}",
            title=title,
        )
        self.db.add(case)
        self.db.flush()
        for person in members:
            self.db.add(CaseMember(case_id=case.id, user_id=person.user.id))
        self.db.commit()
        return case

    def api_key(self, tenant: Tenant, *scopes: str, revoked: bool = False) -> tuple[ApiKey, str]:
        from datetime import UTC, datetime

        secret = api_keys.generate_key()
        key = ApiKey(
            id=new_id("key"),
            tenant_id=tenant.id,
            name="test key",
            prefix=api_keys.display_prefix(secret),
            key_hash=api_keys.hash_key(secret),
            scopes=list(scopes),
            revoked_at=datetime.now(UTC) if revoked else None,
        )
        self.db.add(key)
        self.db.commit()
        return key, secret

    def evidence(self, case: Case, name: str = "purchase_order.pdf") -> EvidenceFile:
        evidence = EvidenceFile(
            id=new_id("evd"),
            tenant_id=case.tenant_id,
            case_id=case.id,
            object_key=f"tenants/{case.tenant_id}/cases/{case.id}/evidence/{new_id('x')}.pdf",
            original_filename=name,
            declared_mime="application/pdf",
            detected_mime="application/pdf",
            byte_size=100,
            status=EvidenceStatus.PROCESSED,
        )
        self.db.add(evidence)
        self.db.commit()
        return evidence

    def claim(
        self, evidence: EvidenceFile, field: str, value: str, quote: str, page: int = 1
    ) -> ExtractedClaim:
        claim = ExtractedClaim(
            id=new_id("clm"),
            tenant_id=evidence.tenant_id,
            case_id=evidence.case_id,
            evidence_id=evidence.id,
            field_name=field,
            raw_value=value,
            normalized_value=value,
            data_type="decimal",
            unit="units",
            source_quote=quote,
            page_index=page,
            grounding="grounded",
            extraction_status="extracted",
            provider="vertex_gemini",
            model="gemini-2.5-flash",
            prompt_version="p1",
            schema_version="s1",
            region="asia-southeast1",
        )
        self.db.add(claim)
        self.db.commit()
        return claim

    def rule(
        self, tenant_id: str, template: RuleTemplate = RuleTemplate.QUANTITY_SHORTFALL
    ) -> Rule:
        rule = self.db.scalar(
            select(Rule).where(Rule.tenant_id == tenant_id, Rule.template == template)
        )
        if rule is None:
            rule = Rule(id=new_id("rule"), tenant_id=tenant_id, template=template)
            self.db.add(rule)
            self.db.commit()
        return rule

    def finding(
        self, case: Case, review_status: ReviewDecision = ReviewDecision.PENDING
    ) -> Finding:
        """The 100 ordered / 80 delivered shortfall from the architecture report."""
        po = self.evidence(case, "purchase_order.pdf")
        dn = self.evidence(case, "delivery_note.pdf")
        ordered = self.claim(po, "ordered_quantity", "100", "Qty ordered: 100")
        delivered = self.claim(dn, "delivered_quantity", "80", "Received: 80")
        rule = self.rule(case.tenant_id)
        finding = Finding(
            id=new_id("fnd"),
            tenant_id=case.tenant_id,
            case_id=case.id,
            rule_id=rule.id,
            rule_version=1,
            finding_type="quantity_shortfall",
            severity="high",
            input_claim_ids=[ordered.id, delivered.id],
            expected={"value": "100", "unit": "units"},
            observed={"value": "80", "unit": "units"},
            difference={"value": "20", "unit": "units"},
            explanation="The purchase order lists 100 units; the delivery note records 80.",
            review_status=review_status,
            dedupe_key=new_id("dk"),
        )
        self.db.add(finding)
        self.db.commit()
        return finding


def key_headers(secret: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"}
