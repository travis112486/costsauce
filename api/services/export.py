# api/services/export.py
import csv
import io
import zipfile

TABLES = {
    "organization.csv": "SELECT id, name, plan, created_at FROM organizations WHERE id = %s",
    "locations.csv": "SELECT id, name, target_fc_pct, drift_threshold_pct "
                     "FROM locations WHERE org_id = %s",
    "members.csv": "SELECT m.user_id, m.role, p.contact_email FROM memberships m "
                   "LEFT JOIN profiles p ON p.user_id = m.user_id WHERE m.org_id = %s",
}


class ExportError(RuntimeError):
    """Raised when a complete, correct export cannot be produced.

    This export is the user's last copy of their org's data before a
    deletion purge. A zip that has the right filenames but a missing or
    empty `organization.csv` still LOOKS complete, and that is worse than a
    request that fails loudly and can be retried or investigated.
    """


async def build_export(conn, org_id: str) -> bytes:
    """Zip a CSV per tenant table, scoped to one org.

    `conn` should be the same connection the caller already has for the
    request -- in production that means a `tenant_connection`-scoped
    connection (SET LOCAL ROLE authenticated + the caller's JWT claims), not
    a bare owner/superuser connection. Every query below is already scoped
    by an explicit `WHERE org_id = %s` / `WHERE id = %s`, so it returns the
    right rows on ANY connection that can read these tables at all -- but a
    tenant_connection adds RLS as a second, independent backstop: even a
    future bug in this file's SQL (wrong column, a query someone forgets to
    filter) can only ever surface rows the caller's own memberships already
    permit, because organizations/locations/memberships are governed by RLS
    policies keyed off current_user_memberships(). A bare owner connection
    (as this project's `raw_conn` test fixture is -- it connects as the
    superuser `postgres`, which bypasses RLS regardless of FORCE) has no
    such backstop; the WHERE clauses are then the ONLY thing standing
    between this function and a cross-tenant leak. This function still
    works correctly against either connection (see
    tests/test_deletion_services.py, which exercises both), but only one of
    them is safe by more than one line of SQL.
    """
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for filename, sql in TABLES.items():
            cur = await conn.execute(sql, (org_id,))
            rows = await cur.fetchall()
            if filename == "organization.csv" and not rows:
                # organizations.id is a primary key, so this is 0-or-1 rows
                # ever -- 0 means either the org doesn't exist, or this
                # connection cannot see it. Either way, continuing on to
                # zip up locations/members would produce a well-formed
                # export for an org that, as far as this export is
                # concerned, does not exist. Fail loudly instead.
                raise ExportError(
                    f"organization {org_id!r} was not found (or is not "
                    "visible on this connection); refusing to emit a "
                    "partial export"
                )
            headers = [d.name for d in cur.description]
            out = io.StringIO()
            w = csv.writer(out)
            w.writerow(headers)
            w.writerows(rows)
            z.writestr(filename, out.getvalue())
    return buf.getvalue()
