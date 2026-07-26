# tests/factories.py
async def make_user(conn, email: str):
    cur = await conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), %s) RETURNING id",
        (email,),
    )
    (user_id,) = await cur.fetchone()
    await conn.execute(
        "INSERT INTO profiles (user_id, contact_email) VALUES (%s, %s)", (user_id, email)
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
