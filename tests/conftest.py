# tests/conftest.py
import os
import pathlib
import subprocess
import time
import uuid
import pytest
import psycopg

MIGRATIONS = pathlib.Path(__file__).parent.parent / "supabase" / "migrations"


@pytest.fixture(scope="session")
def db_url() -> str:
    """A disposable Postgres 17. Never the Supabase project."""
    url = os.environ.get("TEST_DATABASE_URL")
    if url:
        yield url
        return
    name = f"costsauce-test-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        ["docker", "run", "-d", "--rm", "--name", name,
         "-e", "POSTGRES_PASSWORD=postgres", "-P", "postgres:17"],
        check=True, capture_output=True,
    )
    port = subprocess.run(
        ["docker", "port", name, "5432/tcp"],
        check=True, capture_output=True, text=True,
    ).stdout.strip().rsplit(":", 1)[1]
    url = f"postgresql://postgres:postgres@localhost:{port}/postgres"
    for _ in range(60):
        try:
            psycopg.connect(url, connect_timeout=1).close()
            break
        except psycopg.OperationalError:
            time.sleep(0.5)
    else:
        raise RuntimeError("test postgres never became ready")
    yield url
    subprocess.run(["docker", "kill", name], capture_output=True)


async def apply_migrations(conn, upto: int | None = None) -> None:
    for path in sorted(MIGRATIONS.glob("*.sql")):
        number = int(path.name.split("_", 1)[0])
        if upto is not None and number > upto:
            continue
        await conn.execute(path.read_text())
    await conn.commit()


@pytest.fixture
async def raw_conn(db_url):
    """Owner-role connection. Fresh schema per test."""
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    await conn.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
    await conn.execute("DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth")
    await conn.execute(
        "CREATE TABLE auth.users ("
        "  id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb DEFAULT '{}')"
    )
    await conn.commit()
    yield conn
    await conn.close()
