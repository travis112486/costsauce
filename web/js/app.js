// web/js/app.js
// CostSauce SPA shell -- vanilla JS, no build step, no framework.
//
// Flow: captureTokenFromFragment() -> no token: login view (magic-link
// form only when /config has a supabase_url; reviewer OTP form always) ->
// token: GET /me -> org picker (auto when exactly 1 membership) ->
// GET /orgs/{org}/locations -> location picker (auto when exactly 1; zero
// -> explicit "no locations" message) -> persist {org_id, location_id} to
// localStorage (cs_ctx), revalidated against the live membership/location
// lists on every load -> render the dashboard | ingredients | recipes |
// import | settings tab shell. Tab bodies are stubs here; Tasks 5-6 fill
// them in against the frozen api.mjs/auth.mjs/lib.mjs interfaces above.
import { api, ApiError, getToken, clearToken } from "./api.mjs";
import { captureTokenFromFragment, requestMagicLink, reviewerLogin } from "./auth.mjs";
import { pickDefaultMembership } from "./lib.mjs";

const CTX_KEY = "cs_ctx";
const TABS = ["dashboard", "ingredients", "recipes", "import", "settings"];

const root = document.getElementById("app");
const toastEl = document.getElementById("toast");
let toastTimer = null;

// ---------------------------------------------------------------------
// small DOM helpers
// ---------------------------------------------------------------------
function escapeHtml(s) {
  if (s === null || s === undefined) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function toast(msg, isError) {
  if (!toastEl) return;
  toastEl.textContent = msg;
  toastEl.className = "toast show" + (isError ? " error" : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toastEl.className = "toast";
  }, 3800);
}

function errorMessage(e) {
  return e instanceof Error ? e.message : String(e);
}

// ---------------------------------------------------------------------
// cs_ctx (org_id/location_id) persistence
// ---------------------------------------------------------------------
function getCtx() {
  try {
    return JSON.parse(localStorage.getItem(CTX_KEY) || "null");
  } catch (e) {
    return null;
  }
}

function setCtx(ctx) {
  localStorage.setItem(CTX_KEY, JSON.stringify(ctx));
}

function clearCtx() {
  localStorage.removeItem(CTX_KEY);
}

// ---------------------------------------------------------------------
// login view
// ---------------------------------------------------------------------
async function renderLogin() {
  root.innerHTML = `<p class="subtle">Loading…</p>`;

  let config = { supabase_url: null, supabase_anon_key: null };
  try {
    config = await api("/config");
  } catch (e) {
    // /config is unauthenticated and should always succeed; if it doesn't,
    // fall back to reviewer-OTP-only (magic link needs supabase_url).
  }

  const magicLinkCard = config.supabase_url
    ? `
      <div class="card login-card">
        <h3>Sign in with email</h3>
        <form id="magic-link-form">
          <div class="field">
            <label>Email</label>
            <input type="email" id="ml-email" required autocomplete="email">
          </div>
          <button class="btn" type="submit">Send magic link</button>
        </form>
        <div id="ml-result"></div>
      </div>`
    : "";

  root.innerHTML = `
    <div class="login-shell">
      <div class="brand">
        <img src="/app/brand/logo-mark-v2.svg" alt="CostSauce" class="logo">
        <div class="brand-text"><span class="brand-name">CostSauce</span></div>
      </div>
      ${magicLinkCard}
      <div class="card login-card">
        <h3>Reviewer sign-in</h3>
        <form id="reviewer-form">
          <div class="field">
            <label>Email</label>
            <input type="email" id="rv-email" required autocomplete="email">
          </div>
          <div class="field">
            <label>Code</label>
            <input type="text" id="rv-code" required autocomplete="one-time-code">
          </div>
          <button class="btn" type="submit">Sign in</button>
        </form>
        <div id="rv-result"></div>
      </div>
    </div>`;

  const mlForm = document.getElementById("magic-link-form");
  if (mlForm) {
    mlForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const email = document.getElementById("ml-email").value.trim();
      const result = document.getElementById("ml-result");
      try {
        await requestMagicLink(email, config);
        result.innerHTML = `<p class="subtle">Check your email for a sign-in link.</p>`;
      } catch (err) {
        result.innerHTML = `<p class="form-error">${escapeHtml(errorMessage(err))}</p>`;
      }
    });
  }

  document.getElementById("reviewer-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = document.getElementById("rv-email").value.trim();
    const code = document.getElementById("rv-code").value.trim();
    const result = document.getElementById("rv-result");
    try {
      await reviewerLogin(email, code);
      boot();
    } catch (err) {
      result.innerHTML = `<p class="form-error">${escapeHtml(errorMessage(err))}</p>`;
    }
  });
}

// ---------------------------------------------------------------------
// org / location pickers
// ---------------------------------------------------------------------
function renderOrgPicker(me) {
  root.innerHTML = `
    <div class="picker-shell">
      <div class="section-header"><h2>Choose an organization</h2></div>
      <div class="card">
        <div class="picker-list" id="org-picker-list">
          ${me.memberships.map((m) => `
            <button class="picker-option" data-org-id="${escapeHtml(m.org_id)}">
              <span>${escapeHtml(m.org_name)}</span>
              <span class="picker-option-meta">${escapeHtml(m.role)}</span>
            </button>`).join("")}
        </div>
      </div>
      <button class="btn btn-secondary btn-sm" id="picker-sign-out">Sign out</button>
    </div>`;

  document.getElementById("org-picker-list").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-org-id]");
    if (!btn) return;
    const membership = me.memberships.find((m) => m.org_id === btn.dataset.orgId);
    selectOrg(me, membership, null);
  });
  document.getElementById("picker-sign-out").addEventListener("click", signOut);
}

function renderLocationPicker(me, membership, locations) {
  root.innerHTML = `
    <div class="picker-shell">
      <div class="section-header"><h2>Choose a location</h2></div>
      <p class="subtle">${escapeHtml(membership.org_name)}</p>
      <div class="card">
        <div class="picker-list" id="location-picker-list">
          ${locations.map((l) => `
            <button class="picker-option" data-location-id="${escapeHtml(l.id)}">
              <span>${escapeHtml(l.name)}</span>
            </button>`).join("")}
        </div>
      </div>
      <button class="btn btn-secondary btn-sm" id="picker-sign-out">Sign out</button>
    </div>`;

  document.getElementById("location-picker-list").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-location-id]");
    if (!btn) return;
    const location = locations.find((l) => l.id === btn.dataset.locationId);
    setCtx({ org_id: membership.org_id, location_id: location.id });
    renderShell(me, membership, location);
  });
  document.getElementById("picker-sign-out").addEventListener("click", signOut);
}

function renderNoMemberships() {
  root.innerHTML = `
    <div class="picker-shell">
      <div class="empty-state">
        <h3>No organizations yet</h3>
        <p>Your account isn't a member of any organization. Ask an owner to invite you.</p>
      </div>
      <button class="btn btn-secondary btn-sm" id="picker-sign-out">Sign out</button>
    </div>`;
  document.getElementById("picker-sign-out").addEventListener("click", signOut);
}

function renderNoLocations(membership) {
  root.innerHTML = `
    <div class="picker-shell">
      <div class="empty-state">
        <h3>No locations yet</h3>
        <p>${escapeHtml(membership.org_name)} doesn't have any locations set up. Ask an owner or manager to add one.</p>
      </div>
      <button class="btn btn-secondary btn-sm" id="picker-sign-out">Sign out</button>
    </div>`;
  document.getElementById("picker-sign-out").addEventListener("click", signOut);
}

// ---------------------------------------------------------------------
// tab shell (per-tab view bodies land in Tasks 5-6)
// ---------------------------------------------------------------------
function renderShell(me, membership, location) {
  root.innerHTML = `
    <header class="topbar">
      <div class="brand">
        <img src="/app/brand/logo-mark-v2.svg" alt="CostSauce" class="logo">
        <div class="brand-text">
          <span class="brand-name">CostSauce</span>
          <span class="brand-tag" id="restaurant-name">${escapeHtml(location.name)}</span>
        </div>
      </div>
      <nav class="tabs" id="tabs">
        ${TABS.map((t, i) => `<button class="tab-btn${i === 0 ? " active" : ""}" data-tab="${t}">${t.charAt(0).toUpperCase()}${t.slice(1)}</button>`).join("")}
      </nav>
      <button class="btn btn-secondary btn-sm" id="sign-out-btn">Sign out</button>
    </header>
    <main id="tab-content"></main>`;

  document.getElementById("tabs").addEventListener("click", (e) => {
    const btn = e.target.closest(".tab-btn");
    if (!btn) return;
    document.querySelectorAll("#tabs .tab-btn").forEach((b) => b.classList.toggle("active", b === btn));
    renderTabStub(btn.dataset.tab);
  });

  document.getElementById("sign-out-btn").addEventListener("click", signOut);

  renderTabStub(TABS[0]);
}

function renderTabStub(tab) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  const label = tab.charAt(0).toUpperCase() + tab.slice(1);
  content.innerHTML = `
    <div class="empty-state">
      <h3>${escapeHtml(label)}</h3>
      <p>Coming in Task 5/6.</p>
    </div>`;
}

function signOut() {
  clearToken();
  clearCtx();
  renderLogin();
}

// ---------------------------------------------------------------------
// bootstrap
// ---------------------------------------------------------------------
async function selectOrg(me, membership, existingCtx) {
  let locations;
  try {
    locations = await api(`/orgs/${membership.org_id}/locations`);
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) return; // cs:signed-out re-renders
    root.innerHTML = `<div class="empty-state"><h3>Couldn't load locations</h3><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }

  let location = null;
  if (existingCtx && existingCtx.org_id === membership.org_id) {
    location = locations.find((l) => l.id === existingCtx.location_id) || null;
  }

  if (!location) {
    if (locations.length === 1) {
      location = locations[0];
    } else if (locations.length === 0) {
      renderNoLocations(membership);
      return;
    } else {
      renderLocationPicker(me, membership, locations);
      return;
    }
  }

  setCtx({ org_id: membership.org_id, location_id: location.id });
  renderShell(me, membership, location);
}

async function boot() {
  captureTokenFromFragment();

  if (!getToken()) {
    renderLogin();
    return;
  }

  let me;
  try {
    me = await api("/me");
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) return; // cs:signed-out re-renders
    root.innerHTML = `<div class="empty-state"><h3>Couldn't load your account</h3><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }

  const ctx = getCtx();
  let membership = null;
  if (ctx) membership = me.memberships.find((m) => m.org_id === ctx.org_id) || null;
  if (!membership) membership = pickDefaultMembership(me);

  if (!membership) {
    if (me.memberships.length === 0) {
      renderNoMemberships();
    } else {
      renderOrgPicker(me);
    }
    return;
  }

  await selectOrg(me, membership, ctx);
}

window.addEventListener("cs:signed-out", () => {
  clearCtx();
  renderLogin();
});

boot();
