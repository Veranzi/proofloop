"""Rule templates (Docs/Integrations_API_Contract.md §4).

Rules are code. A tenant can only switch a rule on or off and set its
parameters; changing a parameter creates a new version, so a past finding
can always be re-run with the parameters that produced it.
"""

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import Rule, RuleVersion
from app.enums import RuleTemplate
from app.ids import new_id


@dataclass(frozen=True)
class Param:
    key: str
    label: str
    suffix: str
    default: str
    maximum: Decimal | None = None


@dataclass(frozen=True)
class Template:
    name: str
    description: str
    params: tuple[Param, ...]


TEMPLATES: dict[RuleTemplate, Template] = {
    RuleTemplate.QUANTITY_SHORTFALL: Template(
        "Quantity shortfall",
        "Ordered quantity vs delivered quantity, in the same unit.",
        (Param("tolerance_units", "Allowed difference", "units", "0"),),
    ),
    RuleTemplate.AMOUNT_MISMATCH: Template(
        "Amount mismatch",
        "Invoice total vs purchase order total, in the same currency.",
        (Param("tolerance_percent", "Allowed difference", "%", "0", Decimal("100")),),
    ),
    RuleTemplate.DELIVERY_DATE_WINDOW: Template(
        "Late delivery",
        "Delivery date vs the promised date.",
        (Param("grace_days", "Grace period", "days", "0"),),
    ),
    RuleTemplate.MISSING_DOCUMENT: Template(
        "Missing document",
        "An order with no matching delivery note or invoice in the documents reviewed. "
        "This is absence of evidence, not proof that the delivery didn't happen.",
        (),
    ),
}


def defaults(template: RuleTemplate) -> dict[str, str]:
    return {p.key: p.default for p in TEMPLATES[template].params}


def validate_params(template: RuleTemplate, params: dict[str, str]) -> dict[str, str]:
    """Return normalised values, or raise ValueError with a message people can read."""
    allowed = {p.key: p for p in TEMPLATES[template].params}
    unknown = set(params) - set(allowed)
    if unknown:
        raise ValueError(f"Unknown parameter: {', '.join(sorted(unknown))}")
    clean: dict[str, str] = {}
    for key, raw in params.items():
        try:
            value = Decimal(str(raw).strip())
        except InvalidOperation:
            raise ValueError(f"{allowed[key].label} must be a number.") from None
        if not value.is_finite() or value < 0:
            raise ValueError(f"{allowed[key].label} can't be negative.")
        maximum = allowed[key].maximum
        if maximum is not None and value > maximum:
            raise ValueError(f"{allowed[key].label} can be at most {maximum}.")
        clean[key] = format(value.normalize(), "f")
    return clean


def ensure_rules(db: Session, tenant_id: str) -> list[Rule]:
    """Every tenant has one rule per template, created on first use with version 1."""
    existing = {r.template: r for r in db.scalars(select(Rule).where(Rule.tenant_id == tenant_id))}
    for template in TEMPLATES:
        if template not in existing:
            rule = Rule(
                id=new_id("rule"), tenant_id=tenant_id, template=template, current_version=1
            )
            db.add(rule)
            db.flush()
            db.add(
                RuleVersion(id=new_id("rv"), rule_id=rule.id, version=1, params=defaults(template))
            )
            existing[template] = rule
    db.flush()
    return [existing[t] for t in TEMPLATES]


def current_params(db: Session, rule: Rule) -> dict[str, str]:
    version = db.scalar(
        select(RuleVersion).where(
            RuleVersion.rule_id == rule.id, RuleVersion.version == rule.current_version
        )
    )
    params = defaults(RuleTemplate(rule.template))
    if version is not None:
        params.update(version.params)
    return params
