# api/routes/sync.py
import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from psycopg.types.json import Jsonb
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import SyncPushIn
from api.services import sync as svc

router = APIRouter()

# Same literal as api.main.ORG_SCHEDULED_MESSAGE — importing api.main here
# would be circular (main imports this module). Pinned equal by a test.
ORG_SCHEDULED_MESSAGE = "This organization is scheduled for deletion."


async def _require_member_org(conn, org_id):
    """404 for unknown AND non-member alike (RLS hides the row): the same
    deliberate indistinguishability as _require_location."""
    cur = await conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (org_id,))
    row = await cur.fetchone()
    if row is None:
        raise HTTPException(404, "organization not found")
    return row[0]


@router.post("/sync")
async def push(body: SyncPushIn, request: Request,
               caller: CallerIdentity = Depends(require_caller)):
    if len(body.ops) > svc.MAX_BATCH_OPS:
        raise HTTPException(413, f"batch exceeds {svc.MAX_BATCH_OPS} ops")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        scheduled = await _require_member_org(conn, body.org_id)
        if scheduled is not None:
            # §6.2 line 295: check BEFORE applying anything; the device
            # discards its queue on 410. The deletion_guard middleware only
            # covers /orgs/* paths — this check is the one it promised.
            raise HTTPException(410, ORG_SCHEDULED_MESSAGE)
        # Serialize whole batches per org. Without this, two devices racing
        # the same op_id could both miss the ledger read and double-apply:
        # the ledger insert's ON CONFLICT can only dedupe rows, not effects.
        await conn.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s::text, 0))",
            (body.org_id,))
        rank = {t: n for n, t in enumerate(svc.TABLE_ORDER)}
        indexed = sorted(enumerate(body.ops),
                         key=lambda p: (rank[p[1].table], p[0]))
        results: dict[int, dict] = {}
        for idx, op in indexed:
            cur = await conn.execute(
                "SELECT result_json FROM sync_ops WHERE op_id = %s", (op.op_id,))
            row = await cur.fetchone()
            if row is not None:
                results[idx] = {**row[0], "replayed": True}
                continue
            result = {"op_id": str(op.op_id),
                      **await svc.apply_op(conn, body.org_id, op)}
            if result["status"] != "needs_attention":
                # same transaction as the mutation (§5.3). needs_attention is
                # deliberately NOT ledgered: it applied nothing, and the
                # client retries it after fixing the cause.
                await conn.execute(
                    "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
                    " VALUES (%s, %s, %s, %s)",
                    (op.op_id, body.org_id, body.batch_id, Jsonb(result)))
            results[idx] = result
        cur = await conn.execute(
            "SELECT sync_counter FROM organizations WHERE id = %s", (body.org_id,))
        (cursor,) = await cur.fetchone()
    return {"results": [results[i] for i in range(len(body.ops))],
            "cursor": cursor}


@router.get("/sync")
async def pull_changes(org_id: uuid.UUID, request: Request, since: int = 0,
                       caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        # Reads stay available during the deletion grace window -- the export
        # path depends on them; only writes are frozen (§6.2).
        await _require_member_org(conn, org_id)
        return await svc.pull(conn, org_id, since)
