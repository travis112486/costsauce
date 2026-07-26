# api/auth.py
import os
from dataclasses import dataclass
import jwt
from fastapi import HTTPException, Request


@dataclass(frozen=True)
class CallerIdentity:
    user_id: str
    claims: dict


def _decode(token: str) -> dict:
    try:
        return jwt.decode(
            token,
            os.environ["JWT_SECRET"],
            algorithms=["HS256"],
            audience="authenticated",
            issuer=os.environ["JWT_ISSUER"],
            options={"require": ["exp", "sub", "aud", "iss"]},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(401, f"invalid token: {e}")


async def require_caller(request: Request) -> CallerIdentity:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    claims = _decode(header.split(" ", 1)[1])
    return CallerIdentity(user_id=claims["sub"], claims=claims)
