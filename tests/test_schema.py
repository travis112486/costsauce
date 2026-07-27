# tests/test_schema.py
import pytest
from tests.conftest import apply_migrations


async def test_uuidv7_is_time_ordered(raw_conn):
    await apply_migrations(raw_conn, upto=1)
    cur = await raw_conn.execute(
        "SELECT uuid_generate_v7()::text, uuid_generate_v7()::text, uuid_generate_v7()::text"
    )
    a, b, c = await cur.fetchone()
    assert a < b < c, "UUIDv7 must sort in generation order"
    assert a[14] == "7", f"version nibble must be 7, got {a[14]}"


async def test_role_check_rejects_unknown_role(raw_conn):
    await apply_migrations(raw_conn, upto=2)
    cur = await raw_conn.execute(
        "INSERT INTO organizations (name, plan) VALUES ('Acme', 'starter') RETURNING id"
    )
    (org_id,) = await cur.fetchone()
    cur = await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), 'a@x.test') RETURNING id"
    )
    (user_id,) = await cur.fetchone()
    with pytest.raises(Exception) as exc:
        await raw_conn.execute(
            "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'admin')",
            (user_id, org_id),
        )
    assert "memberships_role_check" in str(exc.value)


async def test_contact_email_is_required_on_profiles(raw_conn):
    await apply_migrations(raw_conn, upto=2)
    cur = await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), 'b@x.test') RETURNING id"
    )
    (user_id,) = await cur.fetchone()
    with pytest.raises(Exception) as exc:
        await raw_conn.execute("INSERT INTO profiles (user_id) VALUES (%s)", (user_id,))
    assert "contact_email" in str(exc.value)
