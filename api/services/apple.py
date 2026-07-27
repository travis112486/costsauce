# api/services/apple.py
import httpx

REVOKE_URL = "https://appleid.apple.com/auth/revoke"


class AppleRevokeError(RuntimeError):
    pass


async def revoke_apple_token(refresh_token: str, *, client_id: str,
                             client_secret: str, http: httpx.AsyncClient | None = None) -> None:
    """Apple requires token revocation when a SIWA account is deleted.

    Dormant in this phase: Apple account linking is descoped to Phase 2a
    (see api/routes/identity.py), so no `profiles.apple_sub` is ever set
    today and nothing calls this in practice yet. It is still built and
    tested now because Sign in with Apple remains a locked product decision
    (not an abandoned one) and Apple's guidelines require revocation on
    account deletion regardless of when linking ships.

    Raises AppleRevokeError on any non-2xx response. It deliberately does
    NOT decide whether that should block account deletion -- that policy
    belongs to the deletion flow that calls this (Task 11), which can weigh
    "an already-invalid/expired token is a routine, harmless failure" against
    "a user's own deletion request should not hang on a third-party API"
    however it needs to.
    """
    owns_client = http is None
    http = http or httpx.AsyncClient(timeout=10)
    try:
        resp = await http.post(REVOKE_URL, data={
            "client_id": client_id,
            "client_secret": client_secret,
            "token": refresh_token,
            "token_type_hint": "refresh_token",
        })
        if resp.status_code >= 400:
            raise AppleRevokeError(f"Apple revoke failed {resp.status_code}: {resp.text}")
    finally:
        if owns_client:
            await http.aclose()
