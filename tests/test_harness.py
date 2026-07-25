# tests/test_harness.py
async def test_postgres_is_reachable_and_is_v17(raw_conn):
    cur = await raw_conn.execute("SHOW server_version_num")
    (version_num,) = await cur.fetchone()
    assert int(version_num) >= 170000, f"need Postgres 17+, got {version_num}"
