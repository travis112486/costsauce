// web/js/auth.mjs
// Supabase magic-link + reviewer-OTP auth flows. parseFragment is a pure,
// DOM-free export (tests/js/web-lib.test.mjs imports it directly under
// plain Node); everything else touches window/localStorage/fetch, but only
// inside a function body, never at module top level -- importing this
// module must not execute any browser global.
import { setToken, api, ApiError } from "./api.mjs";

// parseFragment(hash) -> access_token, or null.
//
// Pure: takes a location.hash-shaped string in, returns a string or null,
// touches nothing global. "#access_token=abc&t=x" -> "abc"; "" -> null;
// a fragment with no access_token param -> null.
export function parseFragment(hash) {
  if (!hash) return null;
  const raw = hash.startsWith("#") ? hash.slice(1) : hash;
  if (!raw) return null;
  return new URLSearchParams(raw).get("access_token");
}

// captureTokenFromFragment() -- reads window.location.hash, stores any
// access_token found via parseFragment, then strips the fragment from the
// URL bar (history.replaceState) so a reload/share link doesn't re-carry
// the token. Returns the token, or null if none was present.
export function captureTokenFromFragment() {
  const token = parseFragment(window.location.hash);
  if (token) {
    setToken(token);
    const url = window.location.pathname + window.location.search;
    window.history.replaceState(null, "", url);
  }
  return token;
}

// requestMagicLink(email, config) -- asks Supabase to email a sign-in
// link. config is the /config response ({supabase_url, supabase_anon_key}).
export async function requestMagicLink(email, config) {
  const res = await fetch(`${config.supabase_url}/auth/v1/otp`, {
    method: "POST",
    headers: {
      apikey: config.supabase_anon_key,
      "content-type": "application/json",
    },
    body: JSON.stringify({ email }),
  });
  let data = null;
  try {
    data = await res.json();
  } catch (e) {
    data = null;
  }
  if (!res.ok) {
    const detail = (data && (data.msg || data.error_description)) || data;
    throw new ApiError(res.status, detail);
  }
  return data;
}

// reviewerLogin(email, code) -- fixed-credential sign-in for App Review
// (feature-flagged off in production; POST /auth/reviewer-otp 404s when
// disabled). Stores the returned access_token on success.
export async function reviewerLogin(email, code) {
  const data = await api("/auth/reviewer-otp", { method: "POST", body: { email, code } });
  setToken(data.access_token);
  return data;
}
