// web/js/api.mjs
// Bearer-token API wrapper + token storage. Every browser-only reference
// (localStorage, fetch, window, FormData) lives inside a function body, not
// at module top level -- auth.mjs imports this module and is itself
// imported by the plain-Node test suite, so nothing here may execute a
// browser global just by being imported.

const TOKEN_KEY = "cs_token";

export function setToken(token) {
  localStorage.setItem(TOKEN_KEY, token);
}

export function getToken() {
  return localStorage.getItem(TOKEN_KEY);
}

export function clearToken() {
  localStorage.removeItem(TOKEN_KEY);
}

export class ApiError extends Error {
  constructor(status, detail) {
    const message =
      typeof detail === "string"
        ? detail
        : (detail && detail.message) || `HTTP ${status}`;
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.detail = detail;
  }
}

// api(path, { method, body }) -> parsed JSON, or throws ApiError{status, detail}.
//
// - Adds `Authorization: Bearer <token>` whenever a token is stored.
// - Object bodies are JSON-encoded with a content-type header; FormData
//   bodies pass through untouched (no content-type -- the browser sets the
//   multipart boundary itself).
// - On a 401: clears the stored token, dispatches a `window` CustomEvent
//   named "cs:signed-out" (app.js listens for this to re-render the login
//   view from anywhere a call happens to 401), then throws.
export async function api(path, { method = "GET", body } = {}) {
  const headers = {};
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;

  let payload = body;
  if (body !== undefined && body !== null && !(body instanceof FormData)) {
    headers["content-type"] = "application/json";
    payload = JSON.stringify(body);
  }

  const res = await fetch(path, { method, headers, body: payload });

  let data = null;
  try {
    data = await res.json();
  } catch (e) {
    data = null;
  }

  if (res.status === 401) {
    clearToken();
    window.dispatchEvent(new CustomEvent("cs:signed-out"));
    throw new ApiError(401, data && data.detail);
  }

  if (!res.ok) {
    throw new ApiError(res.status, data && data.detail);
  }

  return data;
}
