# api/main.py
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from api.db import pool_open
from api.routes import identity, me, members
from api.routes.identity import reviewer_otp


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await pool_open(os.environ["DATABASE_URL"])
    yield
    await app.state.pool.close()


def create_app() -> FastAPI:
    app = FastAPI(title="CostSauce API", lifespan=lifespan)
    app.include_router(me.router)
    app.include_router(identity.router)
    app.include_router(members.router)
    app.post("/auth/reviewer-otp", include_in_schema=False)(reviewer_otp)
    return app


app = create_app()
