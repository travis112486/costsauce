# api/main.py
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from api.db import pool_open
from api.routes import me


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await pool_open(os.environ["DATABASE_URL"])
    yield
    await app.state.pool.close()


def create_app() -> FastAPI:
    app = FastAPI(title="CostSauce API", lifespan=lifespan)
    app.include_router(me.router)
    return app


app = create_app()
