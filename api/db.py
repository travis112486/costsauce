# api/db.py
import json
from contextlib import asynccontextmanager
from psycopg_pool import AsyncConnectionPool


class ClaimsLeakError(RuntimeError):
    """Raised when a connection is handed out still carrying prior claims."""


async def pool_open(db_url: str) -> AsyncConnectionPool:
    pool = AsyncConnectionPool(db_url, open=False, min_size=1, max_size=10)
    await pool.open(wait=True)
    return pool


@asynccontextmanager
async def tenant_connection(pool: AsyncConnectionPool, claims: dict):
    """Yield a connection that has adopted the caller's identity.

    Everything happens inside ONE transaction and uses SET LOCAL exclusively,
    so the settings die with the transaction. A plain SET would survive the
    checkout and hand the next caller these claims.
    """
    async with pool.connection() as conn:
        await conn.set_autocommit(False)
        try:
            cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
            (leftover,) = await cur.fetchone()
            if leftover:
                raise ClaimsLeakError(f"connection arrived with claims set: {leftover!r}")

            await conn.execute("SET LOCAL ROLE authenticated")
            await conn.execute(
                "SELECT set_config('request.jwt.claims', %s, true)",
                (json.dumps(claims),),
            )
            yield conn
            await conn.commit()
        except BaseException:
            await conn.rollback()
            raise
