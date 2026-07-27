from tests.conftest import apply_migrations

SAMPLE_ORG = "00000000-0000-7000-8000-00000000cafe"


async def test_seed_shape_and_fictional_vendors(raw_conn):
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT count(*), count(DISTINCT vendor) FROM ingredients i"
        " JOIN locations l ON l.id = i.location_id WHERE l.org_id = %s",
        (SAMPLE_ORG,))
    n, vendors = await cur.fetchone()
    assert (n, vendors) == (5, 5)
    cur = await raw_conn.execute(
        "SELECT bool_and(vendor IN ('Northgate Provisions','Harborline Foods',"
        "'Cedar Valley Produce','Anchor Dairy Co.','Ellsworth Specialty'))"
        " FROM ingredients i JOIN locations l ON l.id = i.location_id"
        " WHERE l.org_id = %s", (SAMPLE_ORG,))
    assert (await cur.fetchone())[0] is True
    cur = await raw_conn.execute(
        "SELECT count(*) FROM purchases p JOIN locations l ON l.id = p.location_id"
        " WHERE l.org_id = %s AND p.source = 'seed'", (SAMPLE_ORG,))
    assert (await cur.fetchone())[0] == 20


async def test_no_seed_rows_outside_sample_org(raw_conn):
    """spec §15's test: no source='seed' row in a non-sample org; and on a
    fresh database no business row of any kind outside the sample org."""
    await apply_migrations(raw_conn)
    for t in ("ingredients", "purchases"):
        cur = await raw_conn.execute(
            f"SELECT count(*) FROM {t} x JOIN locations l ON l.id = x.location_id"
            f" WHERE x.source = 'seed' AND l.org_id != %s", (SAMPLE_ORG,))
        assert (await cur.fetchone())[0] == 0
    for t in ("recipes", "recipe_items"):
        cur = await raw_conn.execute(
            f"SELECT count(*) FROM {t} x JOIN locations l ON l.id = x.location_id"
            f" WHERE l.org_id != %s", (SAMPLE_ORG,))
        assert (await cur.fetchone())[0] == 0


async def test_seed_transient_policies_were_dropped(raw_conn):
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT policyname FROM pg_policies"
        " WHERE policyname LIKE '%%seed_insert%%'")
    assert await cur.fetchall() == []
