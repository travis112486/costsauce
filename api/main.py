# api/main.py
import os
import re
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from api.auth import _decode
from api.db import pool_open, tenant_connection
from api.routes import dashboard, deletion, identity, imports, ingredients, invoices, locations, me, members, purchases, recipes, sync
from api.routes.identity import reviewer_otp

# `/orgs/<id>` and everything beneath it. Anchored and single-segment on
# purpose: the plan's `re.compile(r"/orgs/([0-9a-fA-F-]{36})").search(...)`
# matched anywhere in the path and accepted any 36 characters drawn from the
# hex-and-hyphen alphabet (36 hyphens included). The captured segment is
# parsed with `uuid.UUID` below rather than trusted from the regex.
ORG_PATH = re.compile(r"^/orgs/([^/]+)(?:/|$)")
READ_ONLY = frozenset({"GET", "HEAD", "OPTIONS"})

# Raised by migration 0007's `reject_write_to_scheduled_org` trigger. A custom
# SQLSTATE rather than message matching, so the mapping cannot drift.
ORG_SCHEDULED_SQLSTATE = "CS410"
ORG_SCHEDULED_MESSAGE = "This organization is scheduled for deletion."


async def deletion_guard(request: Request, call_next):
    """Reject writes to an org scheduled for deletion.

    This is the guard the spec requires before any sync batch is applied. A
    device offline through the deletion must have its queue discarded rather
    than resurrecting the data. `POST /sync` does not exist in this phase; the
    guard does, and is what makes that endpoint safe to add later.

    It is NOT the whole guard. A regex over paths cannot see a write whose org
    id is not in the URL -- `POST /invites/accept` is exactly that -- so the
    real invariant is migration 0007's BEFORE trigger on every table carrying
    an org_id, which fires regardless of route, role, or SECURITY DEFINER
    indirection. This middleware exists to turn the common case into a clean
    410 before any work is done; `_scheduled_org_error_handler` below turns the
    trigger's SQLSTATE into the same response for everything else.

    The check runs on the CALLER'S OWN `tenant_connection`, not on a bare
    `app_user` connection or a SECURITY DEFINER boolean:

      * `app_user` is NOINHERIT and holds no grants of its own (0003), so a
        raw `pool.connection()` cannot read `organizations` at all -- it fails
        with `relation "organizations" does not exist`, exactly as Task 9
        discovered for `invites`.
      * a SECURITY DEFINER boolean would answer for ANY caller, turning
        410-vs-403 into an oracle for "is this org being deleted?" against any
        org id an attacker can name. Under RLS a non-member simply sees no
        row, falls through, and gets the route's ordinary 403.

    Anything that is not a clean, authenticated write to a live org falls
    through to the router, which owns the 401/403/404/422 it deserves. This
    function never raises HTTPException: user middleware sits OUTSIDE
    Starlette's ExceptionMiddleware, so an HTTPException raised here would
    become a 500 rather than a status code.
    """
    match = ORG_PATH.match(request.url.path)
    if (
        match is None
        or request.method in READ_ONLY
        # Scheduling and cancelling are the two writes that must still work on
        # an org that is already scheduled. Both handlers do their own
        # authorization and their own grace-window checks.
        #
        # Nothing else is exempt, including `DELETE /orgs/{id}/members/{uid}`.
        # Migration 0007's trigger deliberately does not guard row DELETEs (the
        # purge and its cascade are deletes, and `DELETE /me` must keep
        # working), but roster churn on an org its owner has already condemned
        # is org state change, which is what this guard exists to stop. The
        # member-facing route that must keep working is `DELETE /me`, which is
        # not org-scoped and never matches here.
        #
        # `rstrip("/")` because this middleware sees the RAW path, before
        # Starlette's trailing-slash redirect. Matching on a bare
        # `endswith("/deletion")` meant `DELETE /orgs/{id}/deletion/` missed
        # the exemption and got a 410 from this guard instead of ever reaching
        # the redirect -- so a client that appends a slash could not cancel a
        # scheduled deletion at all, which is precisely the one write this
        # exemption exists to keep available.
        or request.url.path.rstrip("/").endswith("/deletion")
    ):
        return await call_next(request)

    try:
        org_id = uuid.UUID(match.group(1))
    except ValueError:
        return await call_next(request)  # the route will 422 on the path param

    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        return await call_next(request)  # the route will 401
    try:
        claims = _decode(header.split(" ", 1)[1])
    except HTTPException:
        return await call_next(request)  # the route will 401

    async with tenant_connection(request.app.state.pool, claims) as conn:
        cur = await conn.execute(
            "SELECT deletion_scheduled_at IS NOT NULL FROM organizations WHERE id = %s",
            (org_id,),
        )
        row = await cur.fetchone()
    if row is not None and row[0]:
        return JSONResponse({"detail": ORG_SCHEDULED_MESSAGE}, status_code=410)
    return await call_next(request)


async def _scheduled_org_error_handler(request: Request, exc: psycopg.Error):
    """Map migration 0007's trigger to 410, and RLS write denials to 403,
    and nothing else.

    A route with no explicit role check (e.g. `POST /locations/{id}/recipes`)
    relies entirely on the `recipe_write` policy's WITH CHECK to keep a
    bookkeeper from writing recipes. That denial surfaces from psycopg as
    `InsufficientPrivilege` / SQLSTATE 42501 ("new row violates row-level
    security policy"), which is not CS410 -- left unmapped, it would fall
    through this handler's `raise exc` and become an API 500 for a caller
    who is simply the wrong role, instead of a clean 403.
    """
    if getattr(exc, "sqlstate", None) == ORG_SCHEDULED_SQLSTATE:
        return JSONResponse({"detail": ORG_SCHEDULED_MESSAGE}, status_code=410)
    if isinstance(exc, psycopg.errors.InsufficientPrivilege):
        return JSONResponse(
            {"detail": "insufficient role for this action"}, status_code=403)
    raise exc


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await pool_open(os.environ["DATABASE_URL"])
    yield
    await app.state.pool.close()


def create_app() -> FastAPI:
    app = FastAPI(title="CostSauce API", lifespan=lifespan)
    app.middleware("http")(deletion_guard)
    app.add_exception_handler(psycopg.Error, _scheduled_org_error_handler)
    app.include_router(me.router)
    app.include_router(identity.router)
    app.include_router(members.router)
    app.include_router(deletion.router)
    app.include_router(ingredients.router)
    app.include_router(purchases.router)
    app.include_router(imports.router)
    app.include_router(recipes.router)
    app.include_router(dashboard.router)
    app.include_router(locations.router)
    app.include_router(invoices.router)
    app.include_router(sync.router)
    app.post("/auth/reviewer-otp", include_in_schema=False)(reviewer_otp)

    # /config bootstrap endpoint: returns Supabase credentials for SPA init.
    @app.get("/config")
    async def get_config():
        return {
            "supabase_url": os.environ.get("SUPABASE_URL"),
            "supabase_anon_key": os.environ.get("SUPABASE_ANON_KEY"),
        }

    # / redirects to /app/
    @app.get("/", include_in_schema=False)
    async def redirect_to_app():
        return RedirectResponse(url="/app/", status_code=307)

    # Compute paths CWD-independent: repo root is parent of api/ directory.
    repo_root = Path(__file__).resolve().parents[1]
    shared_dir = repo_root / "shared"
    web_dir = repo_root / "web"

    # Mount /shared static files (e.g., kernel.js).
    if shared_dir.is_dir():
        app.mount("/shared", StaticFiles(directory=shared_dir), name="shared")

    # Mount /app static files with html=True to serve index.html at /app/.
    # The SPA is tab-based (no deep links), so no catch-all routing is needed.
    if web_dir.is_dir():
        app.mount("/app", StaticFiles(directory=web_dir, html=True), name="web")

    return app


app = create_app()
