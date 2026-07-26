# api/models.py
from pydantic import BaseModel

PLAN_LIMITS = {
    "starter": {"max_locations": 1, "max_invoices_per_month": 30, "max_recipes": 25, "max_members": 1},
    "growth":  {"max_locations": 1, "max_invoices_per_month": None, "max_recipes": None, "max_members": 3},
    "pro":     {"max_locations": 3, "max_invoices_per_month": None, "max_recipes": None, "max_members": 10},
}


class MembershipOut(BaseModel):
    org_id: str
    org_name: str
    role: str


class EntitlementOut(BaseModel):
    plan: str
    max_locations: int
    max_invoices_per_month: int | None
    max_recipes: int | None
    max_members: int


class MeResponse(BaseModel):
    user_id: str
    # NOT EmailStr: this reflects an already-persisted, already-trusted value
    # (profiles.contact_email, itself `citext` with no format CHECK), not an
    # input being validated at a trust boundary. EmailStr's underlying
    # email_validator library hard-rejects the `.test` TLD via its
    # SPECIAL_USE_DOMAIN_NAMES list (unconditionally, independent of the
    # check_deliverability setting) -- and `.test` is the RFC 2606
    # reserved-for-testing domain this project's fixtures use throughout
    # (tests/factories.py, tests/conftest.py's `seeded`). Keeping EmailStr
    # here would make GET /me permanently unable to serialize its own seed
    # data. Input-side validation belongs on the write path instead (e.g.
    # Task 9's InviteIn.email: EmailStr).
    contact_email: str | None
    contact_email_verified: bool
    apple_linked: bool
    memberships: list[MembershipOut]
    entitlement: EntitlementOut
