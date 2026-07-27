# api/models.py
from datetime import date, datetime
from decimal import Decimal
from typing import Literal
import uuid

from pydantic import BaseModel

PLAN_LIMITS = {
    "starter": {"max_locations": 1, "max_invoices_per_month": 30, "max_recipes": 25, "max_members": 1},
    "growth":  {"max_locations": 1, "max_invoices_per_month": None, "max_recipes": None, "max_members": 3},
    "pro":     {"max_locations": 3, "max_invoices_per_month": None, "max_recipes": None, "max_members": 10},
}


class EntitlementOut(BaseModel):
    plan: str
    max_locations: int
    max_invoices_per_month: int | None
    max_recipes: int | None
    max_members: int


class MembershipOut(BaseModel):
    org_id: str
    org_name: str
    role: str
    # Entitlement lives here, per org, not on MeResponse. A caller can belong
    # to multiple orgs on different plans (the bookkeeper-channel use case:
    # an accountant managing several restaurants), and organizations.plan is
    # an org-level attribute -- there is no single coherent "the caller's
    # plan" once more than one membership exists. A prior version collapsed
    # this to one top-level MeResponse.entitlement by picking rows[0] after
    # ORDER BY o.name, which silently handed a multi-org caller some other
    # org's limits by alphabetical accident. Not a security leak (the row
    # picked was always one of the caller's own orgs, never a stranger's),
    # but a correctness defect for exactly the users this product targets.
    entitlement: EntitlementOut


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
    # No top-level entitlement: see the comment on MembershipOut.entitlement.
    memberships: list[MembershipOut]


class IngredientIn(BaseModel):
    name: str
    base_unit: Literal["lb", "oz", "kg", "g", "each"]
    vendor: str | None = None
    category: str | None = None


class PurchaseIn(BaseModel):
    ingredient_id: uuid.UUID
    purchased_on: date
    qty: Decimal
    unit: str
    total_price: Decimal
    qty_in_case: Decimal | None = None


class RecipeItemIn(BaseModel):
    # stdlib uuid.UUID, not pydantic's UUID4: this project's ids are UUIDv7
    # (see PurchaseIn above), and UUID4's validator rejects them outright.
    id: uuid.UUID | None = None
    ingredient_id: uuid.UUID
    qty_base_units: Decimal


class RecipeIn(BaseModel):
    name: str
    menu_price: Decimal
    target_fc_pct: Decimal = Decimal("30.00")
    items: list[RecipeItemIn] = []


class MergeIn(BaseModel):
    # stdlib uuid.UUID, not pydantic's UUID4: brief erratum -- this project's
    # ids are UUIDv7 (see RecipeItemIn above), and UUID4's validator rejects
    # them outright.
    from_id: uuid.UUID


class SyncOpIn(BaseModel):
    op_id: uuid.UUID
    table: Literal["ingredients", "recipes", "recipe_items", "purchases"]
    row_id: uuid.UUID
    location_id: uuid.UUID
    client_mutated_at: datetime
    fields: dict[str, str | None] = {}


class SyncPushIn(BaseModel):
    org_id: uuid.UUID
    batch_id: uuid.UUID
    ops: list[SyncOpIn]
