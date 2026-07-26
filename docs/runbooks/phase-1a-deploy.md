# Phase 1a Deploy Runbook: Supabase apply and advisor verification

Audience: whoever actually runs the Supabase apply. Assumes no memory of how
Phase 1a was built. Every claim below is sourced from the migration files in
`supabase/migrations/` and the application code in `api/`, not from the
original plan text, which drifted from what was actually shipped in several
places (see "Migration order" below).

**Target project:** `khohfrfqzbieaiikqlsa`. This is a real, human-partner
project. Nothing in this document has been applied to it. Task 14 was scoped
as preparation only; see "Human checklist" at the end for what is still
outstanding.

---

## 1. Migration order

Apply, in this exact numeric order, one file at a time, stopping at the first
error:

```
0001_extensions_and_uuidv7.sql
0002_tenancy_tables.sql
0003_app_user_role.sql
0004_rls_policies.sql
0005_email_verification_binding.sql
0006_accept_invite_definer.sql
0007_deletion.sql
0008_org_purge_accessor.sql
0009_sample_org.sql
```

**The plan's original numbering is stale.** The plan called for `0001`-`0006`,
with deletion and the sample org at `0005`/`0006`. That numbering shifted
**three times** as later tasks found migrations the plan had not budgeted:

- Task 7 (contact-email binding) took `0005`, bumping the plan's deletion
  migration to `0006` and sample-org to `0007`.
- Task 9 (`accept_invite_tx`, fixing a mechanism that did not work as the plan
  literally specified) took `0006`, bumping deletion to `0007` and sample-org
  to `0008`.
- Task 12 (`organizations_pending_purge`, a `FOR UPDATE` accessor the purge
  job needs and the plan did not anticipate) took `0008`, bumping sample-org
  to its final home at `0009`.

If anyone hands you a document, ticket, or memory that says "apply through
`0006`" or "the deletion migration is `0005`," it is describing the plan, not
the repository. Apply through `0009`. Confirm the migrations directory still
has exactly this set and no others before you start:

```bash
ls supabase/migrations/
```

---

## 2. The `app_user` credential

**Decision:** `supabase/migrations/0003_app_user_role.sql` no longer sets a
password. It creates `app_user` `NOLOGIN`. This is deliberate and is not a
placeholder to fill in later in the same file.

**Why this and not the alternatives:**

- *A GUC/env-driven placeholder the runner substitutes* was rejected because
  nothing in this codebase's migration path does text substitution before
  executing a file. `tests/conftest.py`'s `apply_migrations` and Supabase's
  own `apply_migration` tool both send a migration file's bytes verbatim.
  Building a substitution layer would be new, untested infrastructure whose
  only job is smuggling a secret through a file that is, by definition,
  public (committed to git).
- *Splitting `CREATE ROLE` from a same-file `ALTER ROLE ... PASSWORD`* was
  rejected because the password would still have to be a literal in a
  committed file — the exact defect being fixed, just moved a few lines down.
- *`NOLOGIN`, password set out of band* is what shipped. `app_user` exists,
  can become `authenticated` via the `GRANT` immediately below it, but cannot
  authenticate — with any password, known or not — until an operator
  deliberately enables login. There is no known password to ever accidentally
  deploy, because the migration sets none.

**What the operator must do, after `0003` applies and before the API is
pointed at this database:**

```sql
-- Run directly against the Supabase project (SQL editor or psql), never
-- saved to a file this repository tracks.
ALTER ROLE app_user WITH LOGIN PASSWORD '<a freshly generated secret>';
```

Generate the secret with a password manager or `openssl rand -base64 32`, not
by hand. Then build `DATABASE_URL` (see the environment variable table below)
from that password and store it only in the deployment's secret manager /
environment configuration — never in a file that gets committed.

The local test suite performs the disposable-container equivalent of this
same step itself, automatically, with a fixed non-secret password
(`app_pw`) — see `tests/conftest.py`'s `apply_migrations`. That is why the
suite still passes with `0003` no longer containing a password: the two
environments now do the same two-step dance (migration creates the role
inert, something outside the migration makes it usable), they just use
different, independently-chosen secrets for it.

---

## 3. Pre-apply verification

Run these against `khohfrfqzbieaiikqlsa` **before** applying anything, and
resolve every finding before proceeding.

1. **`public` schema must not already contain any of these table names:**
   `organizations`, `memberships`, `locations`, `profiles`, `invites`,
   `email_verifications`, `apple_link_requests`, `deleted_accounts`.
   `list_tables` against the project and check. Migration `0002` issues plain
   `CREATE TABLE` with no `IF NOT EXISTS` guard — if any of these already
   exist (a leftover demo/quickstart artifact is the realistic way this
   happens), the migration fails outright and the apply stops at step 2 of
   9. If any exist and are NOT expected, do not proceed; find out what they
   are and why, and reconcile before touching this migration set.

2. **Is Supabase's `authenticated` role `NOBYPASSRLS NOSUPERUSER`, and does
   it own no application table?** `0003`'s `CREATE ROLE authenticated ...`
   is guarded by `IF NOT EXISTS` — on Supabase this role already exists
   (PostgREST depends on it), so the guard means the `CREATE ROLE` is
   **skipped entirely** and every later `GRANT ... TO authenticated` and
   every RLS policy `TO authenticated` targets whatever role Supabase already
   has, with whatever attributes it already carries. Nothing in this
   migration set verifies those attributes.

   ```sql
   SELECT rolname, rolbypassrls, rolsuper FROM pg_roles WHERE rolname = 'authenticated';
   SELECT c.relname FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
     WHERE r.rolname = 'authenticated';
   ```

   Expected: `rolbypassrls = false`, `rolsuper = false`, zero owned tables.
   **If either boolean is true, every FORCE ROW LEVEL SECURITY policy in this
   entire migration set is decoration for every authenticated request** — the
   single highest-impact silent failure mode this system has. Do not proceed
   until this reads `false`/`false`/zero.

3. **Does Supabase's `postgres` (the identity that will run these
   migrations) carry `BYPASSRLS`?**

   ```sql
   SELECT rolbypassrls, rolsuper FROM pg_roles WHERE rolname = current_user;
   ```

   This does not block the apply either way, but it changes what "success"
   looks like afterwards and it changes what several already-applied
   defenses are protecting against:

   - If `postgres` **bypasses RLS** (superuser or `BYPASSRLS`): the
     `GRANT <definer_role> TO CURRENT_USER` / `REVOKE ... FROM CURRENT_USER`
     dance in `0004`/`0006`/`0007`/`0008` is mostly redundant for the
     migration runner itself (it could already see everything), but it still
     matters for anything else that might one day connect as this same role
     without bypassing.
   - If `postgres` does **not** bypass RLS (the documented, expected case for
     Supabase's migration-running role): every one of the `SECURITY DEFINER`
     workarounds in `0004` (`current_user_memberships`), `0006`
     (`accept_invite_tx`), `0007`/`0008` (`purge_scheduled_orgs`,
     `accounts_pending_identity_purge`, `organizations_pending_purge`) is load
     -bearing, not decorative — without them, the purge job and the
     `deleted_accounts` read path silently return **zero rows** instead of
     erroring. This is the exact failure class this project has hit four
     times already during development (see the divergence audit below); the
     definer-function pattern is how each instance was closed, one at a
     time.

   Record which case applies; it does not change what you do next, but it
   changes what "the purge job returns 0" means when you see it later —
   confirmed zero due work, versus a silent privilege gap.

4. **Consider applying to a Supabase branch/preview first, not the
   production project.** Nothing in this repository has verified, against a
   real (non-superuser, non-bypassing) Supabase migration role, that a
   **file that fails partway through** rolls back cleanly. Every
   multi-statement dance in `0004`/`0006`/`0007`/`0008`/`0009` (the
   definer-role `GRANT`/`REVOKE` bracket, `0009`'s transient seed-insert
   policies) depends on the entire file being one atomic transaction — true
   in the local test harness (confirmed: `tests/conftest.py` sends each
   file's full text through one `conn.execute()` call, and Postgres's simple
   -query protocol implicitly wraps multiple statements with no explicit
   `BEGIN`/`COMMIT` into one all-or-nothing transaction) but **not
   independently verified against Supabase's own `apply_migration`
   mechanism**. If a branch is available, apply there first and deliberately
   break a copy of one of these files (e.g., inject a syntax error near the
   end) to confirm nothing is left half-applied, before trusting the real
   apply.

---

## 4. Applying the migrations

Apply `0001` through `0009`, in order, one call each, using each file's
basename as the migration name. **Stop at the first error** — do not skip
ahead, and do not attempt to patch around an error by hand-editing statements
mid-apply.

If a migration fails partway (see the atomicity caveat in §3.4), before
retrying it, check for leftover privilege on the migration-runner role from
that same file's `GRANT <role> TO CURRENT_USER` dance:

```sql
SELECT g.rolname AS definer_role
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.roleid
JOIN pg_roles g ON g.oid = m.member
WHERE r.rolname IN ('rls_definer', 'invite_definer', 'deletion_definer', 'purge_definer');
```

Expected: zero rows, always, once every migration through `0009` has fully
applied. Any row here means the migration runner is still a member of a
definer role from a prior partial application — `REVOKE <role> FROM
<member>` before retrying anything.

---

## 5. Post-apply verification

Run these against `khohfrfqzbieaiikqlsa` immediately after `0009` applies.

1. **`get_advisors` (type: security). Expect zero advisories of type "RLS
   disabled in public."** Every table this migration set creates
   (`organizations`, `memberships`, `locations`, `invites`, `profiles`,
   `email_verifications`, `apple_link_requests`, `deleted_accounts`) gets
   both `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` in `0004`
   or `0007`. If any advisory names one of these tables, do not consider the
   deploy complete — find out why RLS did not take (do not just add a
   policy and re-apply; find out whether the `ENABLE`/`FORCE` statement
   itself actually ran, per §3.4's atomicity caveat).

2. **Confirm all definer roles exist:** `rls_definer`, `invite_definer`,
   `deletion_definer`, `purge_definer`.

   ```sql
   SELECT rolname, rolcanlogin, rolbypassrls, rolsuper
   FROM pg_roles WHERE rolname IN
     ('rls_definer', 'invite_definer', 'deletion_definer', 'purge_definer');
   ```

   Expected: all four rows present, all four `rolcanlogin = false`,
   `rolbypassrls = false`, `rolsuper = false`.

3. **Confirm `authenticated` has no membership in any definer role** (the
   same query as §4 above, generalized):

   ```sql
   SELECT g.rolname AS member, r.rolname AS definer_role
   FROM pg_auth_members m
   JOIN pg_roles r ON r.oid = m.roleid
   JOIN pg_roles g ON g.oid = m.member
   WHERE r.rolname IN
     ('rls_definer', 'invite_definer', 'deletion_definer', 'purge_definer');
   ```

   Expected: zero rows. If `authenticated` (or `app_user`, or anything an
   ordinary request can reach) appears here, the corresponding
   `SECURITY DEFINER` function's bypass is reachable by every tenant, not
   just through the one narrow function it was built for — this undoes the
   entire recursion-guard / cross-tenant-isolation design in `0004`,
   `0006`, `0007`, `0008`.

4. **Confirm `app_user` cannot log in yet, or logs in with the secret you
   just set — never with `app_pw`:**

   ```sql
   SELECT rolcanlogin FROM pg_roles WHERE rolname = 'app_user';
   ```

   If you have not yet run the `ALTER ROLE` step in §2, this should read
   `false`. After you run it, confirm the API actually connects with the new
   `DATABASE_URL` before considering the deploy live.

---

## 6. Environment variables

| Variable | Read by | What breaks if wrong/missing |
|---|---|---|
| `DATABASE_URL` | API server (`api/main.py`, pooled `app_user` connection) | Every request. Must be the `app_user` credential set in §2 above, pointed at Supabase with `sslmode=require`. Wrong password: the pool never opens, the API never starts. Wrong role (e.g. accidentally the migration-runner credential): `app_user`'s `NOINHERIT` + lack of any grant of its own means most queries fail outright rather than leaking data, but do not rely on that as a safety net — it is `app_user`'s only job to be powerless, not a tested defense against being mis-configured as something else. |
| `PURGE_DATABASE_URL` | Purge job (`api/jobs/purge.py`, run as the migration-runner identity) | **Must be a different credential from `DATABASE_URL`.** `organizations_pending_purge`, `purge_scheduled_orgs`, and `accounts_pending_identity_purge` are `EXECUTE`-granted only to the migration-runner role (`CURRENT_USER` at migration-apply time), never to `authenticated` or `app_user` — deliberately, since `grace` is a caller-supplied argument and a request-path grant would mean any tenant could purge every scheduled org immediately. Using the API's `app_user` credential here fails **every** call with `InsufficientPrivilege`. This is a genuinely separate credential from `DATABASE_URL`, not a naming convention. |
| `JWT_SECRET` | API server (`api/auth.py`, `api/routes/identity.py` reviewer-OTP) | Wrong value: every real token fails to verify (401 for every user). Also used to *mint* the reviewer-OTP token, so it must match whatever Supabase/your auth issuer actually signs with — not an independent secret you invent. |
| `JWT_ISSUER` | API server (`api/auth.py`, reviewer-OTP) | Must equal `https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1` (or the project's actual issuer URL). Wrong value: every real token 401s (`iss` claim mismatch). |
| `STRIPE_API_KEY` | `api/services/billing.py` | Unset: `cancel_subscription` raises `BillingError` for any org that has a real `stripe_customer_id` (it does **not** silently skip — see the deletion route's handling, which schedules the deletion anyway and surfaces a warning). Since no Phase 1a flow populates `stripe_customer_id` yet, this is currently a Phase 5 concern, but set it before the first paying customer. |
| `SUPABASE_URL` | Purge job (`api/jobs/purge.py`, identity-purge half) | Missing/wrong: `purge_pending_identities` raises immediately (`RuntimeError`) rather than silently skipping — the `auth.users` row for every deleted account is never actually removed, which fails App Store guideline 5.1.1(v). |
| `SUPABASE_SERVICE_ROLE_KEY` | Purge job (identity-purge half) | Same failure mode as `SUPABASE_URL` — both are checked together and the job refuses to run without either. Never let this key reach the API server's own process env unnecessarily; it is only used for one Admin API call, in one job. |
| `REVIEWER_OTP_ENABLED` | `api/routes/identity.py` | See §7, its own section — this is the single most sensitive flag in this list. |
| `REVIEWER_EMAIL` / `REVIEWER_CODE` | `api/routes/identity.py` | Reviewer OTP compares the request body against these with `hmac.compare_digest`. Unset: both compare against empty string, which the endpoint explicitly treats as "never a match" (`if not (expected_email and expected_code and ...)`), so reviewer sign-in always 403s rather than accepting a blank credential. |
| `REVIEWER_USER_ID` | `api/routes/identity.py` | The `sub` claim minted into the reviewer's JWT. Must be a real `auth.users.id` on this project (create the reviewer account through normal signup first) with a membership in the sample org — see §9's recommendation on role. Missing: the endpoint raises `KeyError` (uncaught — this is a 500, not a graceful failure; fix the env var, don't work around it in code). |
| `RETURN_INVITE_TOKEN_ENABLED` | `api/routes/members.py` (`create_invite`) | See §8 — must never be `1` in production. |
| `APPLE_REFRESH_TOKEN` / `APPLE_CLIENT_ID` / `APPLE_CLIENT_SECRET` | `api/routes/deletion.py` (`_revoke_apple`) | Dormant in Phase 1a: Apple account linking is descoped to Phase 2a, so `profiles.apple_sub` is always `NULL` and this code path never runs today regardless of these variables. Missing/unset today is harmless. **Also structurally incomplete even once set**: the refresh token is per-user, but no column stores it yet (`_revoke_apple` reads a single global env var) — Phase 2a must add `profiles.apple_refresh_token` and read it from the row before Apple linking actually ships, not rely on this env var for a real user base. |

---

## 7. `REVIEWER_OTP_ENABLED`

**Set to `1` only during the App Review window, and unset it immediately
after the app is approved (or after the review period ends, whichever comes
first).** This flag gates the entire `/auth/reviewer-otp` endpoint — with it
unset, the route 404s unconditionally, before any credential is even
compared.

While it is `1`, the endpoint is a fixed-credential sign-in path, and it is
rate-limited, but the limiter has real, documented gaps an operator should
know before relying on it:

- **5 failed attempts per 60 seconds, per client IP**, and separately a
  **global ceiling of 30 failed attempts total, until the process
  restarts.** The per-IP limiter resets on its own after the window; the
  global ceiling does not reset until the API process is restarted.
- **The global ceiling means an attacker can lock out the real reviewer.**
  30 failed attempts from anywhere — one IP or many — disables the endpoint
  for everyone, including Apple's own reviewer, until someone restarts the
  process. This is a deliberate brute-force defense, not an oversight, but it
  is also a denial-of-service surface with no operator alert wired to it
  today: if App Review reports they cannot sign in, check for this before
  assuming a code/email mismatch.
- **The IP key is `request.client.host`, with no `X-Forwarded-For` handling.**
  Behind any reverse proxy or load balancer, every request arrives from the
  proxy's own address, so the per-IP limiter collapses into one shared
  bucket for all callers — 5 total failures from anyone, anywhere, exhausts
  it, not 5 per real client. If this API is deployed behind a proxy (likely),
  treat the per-IP limit as effectively a second, lower global ceiling until
  someone wires up trusted-proxy `X-Forwarded-For` parsing.
- **Both counters are in-process memory**, not shared across workers or
  restarts. Running more than one API process/worker means each has its own
  independent 5-per-60s and 30-total counters — the effective ceiling scales
  with worker count, and a restart (deploy, crash, autoscale event) silently
  resets both to zero.

---

## 8. `RETURN_INVITE_TOKEN_ENABLED`

**Must never be `1` in production.** With it on, `POST /orgs/{id}/invites`
echoes the raw invite token in its JSON response body. No mailer exists yet
in this codebase (Phase 3 concern) — the token is the entire bearer
credential `accept_invite_tx` (migration `0006`) accepts, bound only to the
invite's target email, so leaking it anywhere the intended invitee did not
request it is a real account-takeover surface for that org.

It exists purely so the local test suite can exercise the accept-invite round
trip without a mailer (`tests/conftest.py`'s `app_client` fixture sets it).
There is no legitimate reason for it to be `1` outside a test process.

---

## 9. The purge job

`api/jobs/purge.py` is meant to run **daily via cron**, as the
**migration-runner identity** (see the `PURGE_DATABASE_URL` row in §6 — not
`app_user`, not `DATABASE_URL`). Example crontab entry:

```cron
0 3 * * * cd /path/to/deployment && \
  PURGE_DATABASE_URL="postgresql://<migration-runner>:<password>@<host>/postgres?sslmode=require" \
  SUPABASE_URL="https://khohfrfqzbieaiikqlsa.supabase.co" \
  SUPABASE_SERVICE_ROLE_KEY="<service role key>" \
  /path/to/venv/bin/python -m api.jobs.purge >> /var/log/costsauce-purge.log 2>&1
```

It has two independent halves (organization purge, identity purge via
Supabase's Admin API), attempted regardless of whether the other fails, and
the exit code reflects either half failing.

**`storage_delete` has no real backend wired in yet. Any purge run that
actually has organizations to purge will exit non-zero by design, and this
is expected, not an incident.** `run_purge` is written to still complete the
organization purge (the row is not held hostage to a bucket that does not
exist), but it deliberately raises `StorageNotConfiguredError` afterward so a
misconfigured deployment cannot look like a healthy no-op night just because
nothing logged an error loudly. Read the log line first
(`storage_delete is not configured; storage objects for N organization(s)
... will NOT be deleted`) before treating a non-zero exit as a real failure.
A run with **nothing** due for purge exits 0 normally. Wire a real
`storage_delete` callback (and a storage bucket — see §10) before this
becomes a false alarm anyone pages on.

---

## 10. Known production gaps — do not be surprised by these

- **No storage bucket exists anywhere in this project yet.** `storage_delete`
  (§9) has nothing to call. This is a known, tracked gap, not a regression.
- **The reviewer-OTP IP limiter has no `X-Forwarded-For` handling** and its
  counters are per-process, not shared — both detailed in §7.
- **The 30-day deletion grace window (`GRACE_DAYS` in
  `api/routes/deletion.py`) is a human-partner product decision and MUST be
  stated in the privacy policy.** Nothing in the app surfaces this to a user
  outside the deletion-confirmation response itself; the privacy policy is
  the only other place a user would learn it before requesting deletion.
- **Cancelling an organization deletion does NOT restore a cancelled Stripe
  subscription.** `DELETE /orgs/{id}/deletion` explicitly returns
  `"subscription_restored": false` and says so in its response `detail`. If
  a subscription was cancelled when the deletion was confirmed, cancelling
  the deletion leaves that org with no subscription; someone has to
  re-create it manually. This is current, intended behavior, not a bug to
  fix under Phase 1a.
- **`organizations.stripe_customer_id` is never populated by any Phase 1a
  code.** `cancel_subscription` no-ops on `None` (nothing to cancel, for
  every org today), so this is safe as shipped, but it must be wired up
  before the first paying customer, or org deletion will schedule
  successfully while silently never touching a real subscription.

---

## 11. The sample org and the reviewer account

Migration `0009` seeds a fixed sample organization
(`00000000-0000-7000-8000-00000000cafe`, "The Copper Ladle (Sample)", plan
`pro`) with one location, but deliberately creates **no membership** for it —
`REVIEWER_USER_ID` is a per-deployment env var that does not exist at
migration-authoring time, so wiring the reviewer's membership is an ops step,
done here, once `REVIEWER_USER_ID` is known.

1. Create the reviewer's real account through the app's normal sign-in flow
   (or the Supabase dashboard) first, so `REVIEWER_USER_ID` is a genuine
   `auth.users.id`.
2. Insert its membership in the sample org:

   ```sql
   INSERT INTO memberships (user_id, org_id, role)
   VALUES ('<REVIEWER_USER_ID>', '00000000-0000-7000-8000-00000000cafe', 'manager');
   ```

**Recommendation: `manager`, not `owner`.** An `owner` membership can call
`POST /orgs/{id}/deletion` and schedule the shared demo org for deletion —
App Review must not be able to do that to the one org every future reviewer
also depends on. `manager` still sees the full feature set the `pro` plan
unlocks (this org was deliberately seeded on `pro` so review is not blocked
by entitlement limits) without the owner-only deletion/export/invite
surface.

Whether this `INSERT` can run directly as the migration runner via the SQL
editor, or needs the service-role REST path instead, depends on the §3.3
finding (whether `postgres` bypasses RLS on this project) — `memberships` is
`FORCE ROW LEVEL SECURITY` with policies scoped `TO authenticated` and no
policy at all for a plain, non-bypassing migration-runner role. If the SQL
editor's `INSERT` returns success but `SELECT` afterward shows zero rows,
that is this exact gap — retry through the service-role key against
Supabase's REST API instead (`POST /rest/v1/memberships`), which bypasses
RLS by design.

---

## 12. Migration audit: production-vs-local divergence

Full findings from this task's audit, several already touched on above,
collected here as one list.

1. **`0003` — `app_user` password.** Fixed this task; see §2.

2. **`0003` — `authenticated` adopted via `CREATE ROLE ... IF NOT EXISTS`.**
   Supabase already owns a role named `authenticated`; the guard means our
   `CREATE ROLE` is skipped and every later grant/policy targets Supabase's
   existing role with whatever attributes it already has. Nothing in this
   migration asserts `NOBYPASSRLS`/`NOSUPERUSER`/table ownership for it. See
   §3.2 for the required pre-apply check.

3. **`0003` — blanket `GRANT ... ON ALL TABLES IN SCHEMA public TO
   authenticated`.** Widens to every table already in `public`, not only the
   ones this migration set creates. Combined with `0002`'s un-guarded
   `CREATE TABLE` (no `IF NOT EXISTS`), a pre-existing table with a colliding
   name either (a) gets silently exposed to every tenant if its name does
   not collide, or (b) stops the whole apply outright at that `CREATE TABLE`
   if it does. See §3.1.

4. **Definer roles (`rls_definer` `0004`, `invite_definer` `0006`,
   `deletion_definer` + `purge_definer` `0007`, `purge_definer` reused
   `0008`) and their owned `SECURITY DEFINER` functions.** Role creation is
   idempotent (`IF NOT EXISTS` guard) and every function uses `CREATE OR
   REPLACE FUNCTION`, so re-applying the specific statements that create
   them is safe *in isolation*. What is **not** independently safe is the
   surrounding `GRANT <role> TO CURRENT_USER` / `... REVOKE ... FROM
   CURRENT_USER` bracket if the file fails midway (see finding 6) — a
   mid-file failure between the `GRANT` and the `REVOKE` leaves the
   migration runner a live member of the definer role, silently softening
   FORCE ROW LEVEL SECURITY for that connection (`has_privs_of_role()`
   semantics; only visible via `pg_auth_members`, not `pg_has_role()`, since
   the latter always answers true for a superuser). §4/§5 give the exact
   query to check this both before retrying a failed apply and as part of
   post-apply verification.

5. **`0009`'s transient `organizations_seed_insert` /
   `locations_seed_insert` policy bracket.** Scoped `TO CURRENT_USER`,
   created immediately before two seed `INSERT`s and `DROP`ped immediately
   after, in the same file. If the file fails between the `CREATE POLICY`
   and the `DROP POLICY` (e.g. the `INSERT` itself errors), the migration
   runner is left holding a **permanent** INSERT bypass on
   `organizations`/`locations` — silently undoing `0004`'s stated invariant
   that `organizations` carries no INSERT policy. Same atomicity dependency
   as finding 4, higher stakes because nothing else ever revokes it.

6. **File-level atomicity is assumed, not independently verified against
   Supabase.** Every multi-statement dance above depends on the whole
   migration file running as one all-or-nothing transaction. Confirmed true
   in the local harness (Postgres's simple-query protocol implicitly wraps
   multiple statements with no explicit `BEGIN`/`COMMIT` into one
   transaction, and `tests/conftest.py` sends each file as one `conn.execute`
   call). Whether Supabase's `apply_migration` preserves this has not been
   checked against the live project — no MCP access was available for this
   task, and the project was off-limits regardless. See §3.4's
   branch-testing recommendation.

7. **`ALTER DEFAULT PRIVILEGES IN SCHEMA public ... TO authenticated`
   (`0003`)** only binds to objects later created by the same role that
   issued it. Fine as long as every future migration is applied through the
   same mechanism/identity, which Supabase's own tooling should guarantee —
   flagged here as a forward-looking note for Phase 1b+, not a Phase 1a
   defect.

8. **The test harness's own RLS-bypass blind spot.** `raw_conn`/`db_url`
   connect as a genuine Postgres superuser in every test, which bypasses
   FORCE RLS regardless of any of the above — a fact the migrations'
   own comments call out repeatedly (`0007`, `0008`, `0009` each have a
   dedicated non-superuser-role test specifically to compensate for this).
   This project has hit the "silently returns zero rows under FORCE RLS for
   a non-superuser role" failure class **four times** during development
   (the `rls_definer` REVOKE dance, `0006`'s switch to advisory locks after
   `FOR UPDATE` failed open under RLS, all of `0008`, and `0009`'s seed
   -insert policy). This audit did not find a fifth occurrence, but the
   underlying pattern — code exercised only against a bypassing connection
   locally — is the single biggest residual risk in this deploy. Anything
   written after this point that touches `organizations`, `memberships`, or
   any other FORCE RLS table, and is tested only against `raw_conn`, is
   unverified for what actually happens on Supabase.

---

## 13. Human checklist — what is left before this can go live

In order. Nothing above this line has been applied to `khohfrfqzbieaiikqlsa`.

1. **Decide who runs the apply and when**, with the human partner's explicit
   go-ahead — this is an outward-facing, hard-to-reverse action against a
   real project.
2. **Run the §3 pre-apply checks** against `khohfrfqzbieaiikqlsa`
   (`list_tables`, the `authenticated`/`postgres` role-attribute queries).
   Resolve every finding before proceeding, especially §3.2
   (`authenticated`'s `BYPASSRLS`/`SUPERUSER`/table ownership).
3. **If a Supabase branch/preview is available, apply there first** and
   deliberately break a copy of one migration to confirm clean rollback,
   per §3.4.
4. **Apply `0001` through `0009`** to `khohfrfqzbieaiikqlsa`, in order, one
   call each, stopping at the first error. If one fails, run the §4
   leftover-privilege check before any retry.
5. **Run the §5 post-apply verification**: `get_advisors` (zero "RLS
   disabled in public"), all four definer roles present and unreachable,
   `authenticated` a member of none of them.
6. **Set the `app_user` password out of band** (§2) and build the real
   `DATABASE_URL`. Confirm the API actually connects with it.
7. **Provision every environment variable in §6** for the API server and the
   purge job's cron entry, using two distinct database credentials for
   `DATABASE_URL` and `PURGE_DATABASE_URL`.
8. **Create the reviewer account and wire its sample-org membership** (§11),
   as `manager`, before submitting for App Review.
9. **Set `REVIEWER_OTP_ENABLED=1` only for the App Review window** and put a
   reminder in place to unset it the moment review concludes (§7). Confirm
   `RETURN_INVITE_TOKEN_ENABLED` is not set to `1` anywhere in this
   environment (§8).
10. **Schedule the purge job's daily cron entry** (§9) as the
    migration-runner identity. Expect it to exit non-zero the first time it
    has real work and no `storage_delete` wired up — that is expected, not
    an incident, until a storage backend exists.
11. **Add the 30-day deletion grace window to the privacy policy** (§10) if
    it is not already stated there.
12. **Track `organizations.stripe_customer_id` wiring as a pre-launch
    blocker**, not a Phase 1a task — confirm someone owns it before the
    first paying customer.
