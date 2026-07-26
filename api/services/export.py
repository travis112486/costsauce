# api/services/export.py
import csv
import io
import zipfile


class ExportError(RuntimeError):
    """Raised when a complete, correct export cannot be produced.

    This export is the user's last copy of their org's data before a
    deletion purge. A zip that has the right filenames but a missing or
    empty file that should never be empty still LOOKS complete, and that is
    worse than a request that fails loudly and can be retried or
    investigated.
    """


# Schema audit (review round 1, Important-1): every table this project has
# today is one of the seven in TENANT_TABLES (tests/conftest.py), all
# defined in supabase/migrations/0002_tenancy_tables.sql. Each is accounted
# for below, in one of the two dicts, with a reason:
#
#   organizations        -> _ORG_SQL below (the export's own subject; not
#                            in TABLES because it is resolved and checked
#                            before anything else, see build_export)
#   locations             -> TABLES["locations.csv"]
#   memberships           -> TABLES["members.csv"]
#   invites               -> TABLES["invites.csv"] (org_id NOT NULL FK to
#                            organizations, migration 0002 lines 40-51;
#                            missed in the first version of this file)
#   profiles              -> DELIBERATELY EXCLUDED. No org_id column and no
#                            path to one: a profile belongs to a user, not
#                            an org, and one user can hold memberships in
#                            several orgs (the bookkeeper-channel case
#                            documented in api/models.py). The slice of a
#                            profile that IS this org's business -- which
#                            users are members, and their contact address --
#                            is already carried by members.csv's join.
#                            Exporting full profiles here would mean
#                            exporting another org's member's account data
#                            (apple_sub, verification timestamp) as if it
#                            were this org's to hand over, which it is not.
#   email_verifications   -> DELIBERATELY EXCLUDED. Same reasoning as
#                            profiles: keyed on user_id only, no org_id, not
#                            org-scoped data.
#   apple_link_requests    -> DELIBERATELY EXCLUDED. Same reasoning again,
#                            and additionally dormant: Apple account linking
#                            is descoped to Phase 2a (api/routes/identity.py),
#                            so this table is unused by any live account
#                            today.
_ORG_SQL = "SELECT id, name, plan, created_at FROM organizations WHERE id = %s"

# Per table: (sql, must_be_non_empty).
#
# must_be_non_empty says whether a ZERO-row result is itself evidence of a
# broken export -- an invariant elsewhere in this schema guarantees a real,
# visible org can never have zero of these -- as opposed to a table an org
# may legitimately have nothing in yet.
#
#   locations  -- legitimately empty. No route creates locations yet (no
#                 /locations endpoint exists in api/routes/ as of Task 10),
#                 and PLAN_LIMITS (api/models.py) only ever caps
#                 max_locations, it never enforces a minimum.
#   members    -- must never be empty for an org this function can already
#                 see. remove_member, change_role, and accept_invite_tx
#                 (supabase/migrations/0006_accept_invite_definer.sql,
#                 the last-owner-conflict checks) all refuse to let an
#                 org's owner count reach zero, so a zero-row memberships
#                 result for an org that itself resolved above means either
#                 a WHERE-clause bug in THIS file, or (under a
#                 tenant_connection) the RLS-visible set shifting out from
#                 under the export mid-flight -- never a legitimate state.
#   invites    -- legitimately empty. Most orgs have no pending invitation
#                 at any given moment; zero is the common case, not a bug.
TABLES = {
    "locations.csv": (
        "SELECT id, name, target_fc_pct, drift_threshold_pct "
        "FROM locations WHERE org_id = %s",
        False,
    ),
    "members.csv": (
        "SELECT m.user_id, m.role, p.contact_email FROM memberships m "
        "LEFT JOIN profiles p ON p.user_id = m.user_id WHERE m.org_id = %s",
        True,
    ),
    "invites.csv": (
        "SELECT id, email, role, invited_by, expires_at, accepted_at, created_at "
        "FROM invites WHERE org_id = %s",
        False,
    ),
}


def _rows_to_csv(headers, rows) -> str:
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(headers)
    w.writerows(rows)
    return out.getvalue()


async def build_export(conn, org_id: str) -> bytes:
    """Zip a CSV per org-scoped tenant table.

    `conn` should be the same connection the caller already has for the
    request -- in production that means a `tenant_connection`-scoped
    connection (SET LOCAL ROLE authenticated + the caller's JWT claims), not
    a bare owner/superuser connection. Every query here is already scoped by
    an explicit `WHERE org_id = %s` / `WHERE id = %s`, so it returns the
    right rows on ANY connection that can read these tables at all -- but a
    tenant_connection adds RLS as a second, independent backstop: even a
    future bug in this file's SQL (wrong column, a query someone forgets to
    filter) can only ever surface rows the caller's own memberships already
    permit, because organizations/locations/memberships/invites are governed
    by RLS policies keyed off current_user_memberships(). A bare owner
    connection (as this project's `raw_conn` test fixture is -- it connects
    as the superuser `postgres`, which bypasses RLS regardless of FORCE) has
    no such backstop; the WHERE clauses are then the ONLY thing standing
    between this function and a cross-tenant leak. This function works
    correctly against either connection (see tests/test_deletion_services.py,
    which exercises both), but only one of them is safe by more than one
    line of SQL.
    """
    # The org row is resolved and checked FIRST, unconditionally -- via a
    # direct lookup, not by relying on being first in TABLES. Dict iteration
    # order is not a safety mechanism: reordering TABLES (or adding a table
    # ahead of this one) must not be able to reintroduce a well-formed zip
    # for an org that does not exist or is not visible on this connection.
    cur = await conn.execute(_ORG_SQL, (org_id,))
    org_rows = await cur.fetchall()
    if not org_rows:
        # organizations.id is a primary key, so this is 0-or-1 rows ever --
        # 0 means either the org doesn't exist, or this connection cannot
        # see it. Either way, going on to zip up locations/members/invites
        # would produce a well-formed export for an org that, as far as
        # this export is concerned, does not exist. Fail loudly instead.
        raise ExportError(
            f"organization {org_id!r} was not found (or is not visible on "
            "this connection); refusing to emit a partial export"
        )
    org_headers = [d.name for d in cur.description]

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("organization.csv", _rows_to_csv(org_headers, org_rows))
        for filename, (sql, must_be_non_empty) in TABLES.items():
            cur = await conn.execute(sql, (org_id,))
            rows = await cur.fetchall()
            if must_be_non_empty and not rows:
                raise ExportError(
                    f"{filename} was unexpectedly empty for org {org_id!r}; "
                    "an org build_export can already see must have at "
                    "least one member; refusing to emit a partial export"
                )
            headers = [d.name for d in cur.description]
            z.writestr(filename, _rows_to_csv(headers, rows))
    return buf.getvalue()
