"""Phase 3a: pre-signed invoice-page uploads and their confirmation.

Two endpoints rather than one. A pre-signed PUT succeeding tells the CLIENT
the bytes arrived but leaves the server with no record that they did --
without confirm, `storage_path` is a claim nobody checked, and 3b's parse
worker would dispatch against pages that may not exist.
"""
import os
import uuid
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection

router = APIRouter()

BUCKET = "invoices"
UPLOAD_URL_TTL_SECONDS = 3600


def storage_path(org_id, invoice_id, page_no: int) -> str:
    """The one definition of the key.

    CostSauceKit's `StoragePath.forPage` reproduces this exactly and is
    pinned against it by its own test. The client derives the key so a retry
    overwrites rather than duplicates (spec §4); this side derives it too and
    never accepts one from the client, so a divergence cannot put bytes
    somewhere nothing reads.
    """
    return f"{org_id}/{invoice_id}/{page_no}.jpg"


async def sign_put(path: str):
    """A pre-signed upload URL for `path`, and when it expires.

    Service-role, never the anon key: this signs a write into a PRIVATE
    bucket. The token is scoped to this exact object path, so it grants
    nothing beyond the single page it was minted for.

    Minted per attempt rather than cached -- the device uploads over a
    background session that may not run until hours later (a phone that left
    the building mid-delivery), by which point a cached URL has expired.
    """
    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            f"{base}/storage/v1/object/upload/sign/{BUCKET}/{path}",
            headers={"Authorization": f"Bearer {key}"},
            json={"expiresIn": UPLOAD_URL_TTL_SECONDS},
        )
    if response.status_code != 200:
        raise HTTPException(502, "could not sign the upload URL")
    signed = response.json()["url"]
    expires_at = (
        datetime.now(timezone.utc) + timedelta(seconds=UPLOAD_URL_TTL_SECONDS)
    ).isoformat()
    return f"{base}/storage/v1{signed}", expires_at


async def sign_get(path: str):
    """A pre-signed download URL for `path`, and when it expires.

    The mirror of `sign_put`, with one difference that will bite anyone who
    copies that function: Supabase's DOWNLOAD signing endpoint returns its
    path under `signedURL`, while the UPLOAD one returns `url`. A copy-paste
    raises KeyError against real Supabase while passing against any stub
    that happens to return `url`.
    """
    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            f"{base}/storage/v1/object/sign/{BUCKET}/{path}",
            headers={"Authorization": f"Bearer {key}"},
            json={"expiresIn": UPLOAD_URL_TTL_SECONDS},
        )
    if response.status_code != 200:
        raise HTTPException(502, "could not sign the download URL")
    payload = response.json()
    # Both spellings are accepted deliberately -- the spec records the key as
    # an expectation, not a verified fact. A 200 carrying NEITHER is storage
    # changing its contract, and that is a bad gateway, not a KeyError that
    # FastAPI would render as an opaque 500.
    signed = payload.get("signedURL") or payload.get("url")
    if not signed:
        raise HTTPException(502, "storage signed no download URL")
    expires_at = (
        datetime.now(timezone.utc) + timedelta(seconds=UPLOAD_URL_TTL_SECONDS)
    ).isoformat()
    return f"{base}/storage/v1{signed}", expires_at


class ConfirmBody(BaseModel):
    sha256: str = Field(min_length=64, max_length=64)
    width: int = Field(gt=0)
    height: int = Field(gt=0)


async def _invoice_org(conn, invoice_id: uuid.UUID):
    """The invoice's org, or 404.

    RLS already hides other orgs' invoices, so a miss here is either
    genuinely absent or not ours. Both answer 404 -- distinguishing them
    would leak the existence of another org's invoice.
    """
    cur = await conn.execute(
        "SELECT l.org_id FROM invoices i JOIN locations l ON l.id = i.location_id"
        " WHERE i.id = %s AND i.deleted_at IS NULL", (invoice_id,))
    row = await cur.fetchone()
    if row is None:
        raise HTTPException(404, "invoice not found")
    return row[0]


@router.post("/invoices/{invoice_id}/pages/{page_no}/upload-url")
async def mint_upload_url(invoice_id: uuid.UUID, page_no: int, request: Request,
                          caller: CallerIdentity = Depends(require_caller)):
    if page_no < 1:
        raise HTTPException(422, "page_no must be positive")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        org_id = await _invoice_org(conn, invoice_id)
    path = storage_path(org_id, invoice_id, page_no)
    url, expires_at = await sign_put(path)
    return {"url": url, "storage_path": path, "expires_at": expires_at}


@router.post("/invoices/{invoice_id}/pages/{page_no}/confirm", status_code=204)
async def confirm_upload(invoice_id: uuid.UUID, page_no: int, body: ConfirmBody,
                         request: Request,
                         caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _invoice_org(conn, invoice_id)
        cur = await conn.execute(
            "UPDATE invoice_pages SET sha256 = %s, width = %s, height = %s,"
            " updated_at = now()"
            " WHERE invoice_id = %s AND page_no = %s AND deleted_at IS NULL"
            " RETURNING id",
            (body.sha256, body.width, body.height, invoice_id, page_no))
        if await cur.fetchone() is None:
            raise HTTPException(404, "page not found")
    return Response(status_code=204)


@router.post("/invoices/{invoice_id}/pages/{page_no}/download-url")
async def mint_download_url(invoice_id: uuid.UUID, page_no: int, request: Request,
                            caller: CallerIdentity = Depends(require_caller)):
    """A signed GET for a page whose bytes are confirmed present.

    409 rather than 404 when `sha256` is null: the row exists and is ours,
    it simply has no bytes in the bucket yet, and a signed URL would resolve
    to nothing. 404 stays reserved for absent-or-another-org's (`_invoice_org`).
    """
    if page_no < 1:
        raise HTTPException(422, "page_no must be positive")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        org_id = await _invoice_org(conn, invoice_id)
        cur = await conn.execute(
            "SELECT sha256 FROM invoice_pages"
            " WHERE invoice_id = %s AND page_no = %s AND deleted_at IS NULL",
            (invoice_id, page_no))
        row = await cur.fetchone()
    if row is None:
        raise HTTPException(404, "page not found")
    if row[0] is None:
        raise HTTPException(409, "page bytes are not confirmed")
    url, expires_at = await sign_get(storage_path(org_id, invoice_id, page_no))
    return {"url": url, "expires_at": expires_at}
