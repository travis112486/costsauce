# tests/factories.py
async def make_user(conn, email: str, *, contact_email_verified: bool = False):
    cur = await conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), %s) RETURNING id",
        (email,),
    )
    (user_id,) = await cur.fetchone()
    # contact_email_verified defaults False (existing callers' behavior is
    # unchanged); Task 9 review round 2 requires an invite's acceptance to be
    # bound to a VERIFIED profiles.contact_email, so tests exercising that
    # path pass contact_email_verified=True explicitly.
    await conn.execute(
        "INSERT INTO profiles (user_id, contact_email, contact_email_verified_at) "
        "VALUES (%s, %s, CASE WHEN %s THEN now() ELSE NULL END)",
        (user_id, email, contact_email_verified),
    )
    return user_id


async def make_org(conn, name: str, plan: str = "starter"):
    cur = await conn.execute(
        "INSERT INTO organizations (name, plan) VALUES (%s, %s) RETURNING id", (name, plan)
    )
    (org_id,) = await cur.fetchone()
    return org_id


async def add_member(conn, user_id, org_id, role: str):
    cur = await conn.execute(
        "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, %s) RETURNING id",
        (user_id, org_id, role),
    )
    (mid,) = await cur.fetchone()
    return mid


async def make_location(conn, org_id, name: str):
    cur = await conn.execute(
        "INSERT INTO locations (org_id, name) VALUES (%s, %s) RETURNING id", (org_id, name)
    )
    (loc_id,) = await cur.fetchone()
    return loc_id


async def make_ingredient(conn, location_id, name, base_unit="lb",
                          vendor=None, category=None, source="manual"):
    cur = await conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit, vendor, category, source)"
        " VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
        (location_id, name, base_unit, vendor, category, source))
    (iid,) = await cur.fetchone()
    return iid


async def make_purchase(conn, location_id, ingredient_id, purchased_on,
                        qty_base_units, total_price, *, recorded_at=None,
                        unit="lb", qty=None, source="manual"):
    # qty defaults to qty_base_units: most tests only care about the
    # normalized quantity; the raw entry fields exist for display parity.
    cur = await conn.execute(
        "INSERT INTO purchases (location_id, ingredient_id, purchased_on,"
        " recorded_at, qty, unit, qty_base_units, total_price, source)"
        " VALUES (%s, %s, %s, COALESCE(%s, now()), %s, %s, %s, %s, %s) RETURNING id",
        (location_id, ingredient_id, purchased_on, recorded_at,
         qty or qty_base_units, unit, qty_base_units, total_price, source))
    (pid,) = await cur.fetchone()
    return pid


async def make_recipe(conn, location_id, name, menu_price, target_fc_pct="30.00"):
    cur = await conn.execute(
        "INSERT INTO recipes (location_id, name, menu_price, target_fc_pct)"
        " VALUES (%s, %s, %s, %s) RETURNING id",
        (location_id, name, menu_price, target_fc_pct))
    (rid,) = await cur.fetchone()
    return rid


async def add_recipe_item(conn, location_id, recipe_id, ingredient_id, qty_base_units):
    cur = await conn.execute(
        "INSERT INTO recipe_items (location_id, recipe_id, ingredient_id, qty_base_units)"
        " VALUES (%s, %s, %s, %s) RETURNING id",
        (location_id, recipe_id, ingredient_id, qty_base_units))
    (iid,) = await cur.fetchone()
    return iid
