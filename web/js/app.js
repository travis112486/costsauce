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
import {
  pickDefaultMembership, money, pct, signedPct, todayLocalISO,
  barWidths, sparklinePoints, buildPurchasePayload,
} from "./lib.mjs";

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
    renderTab(btn.dataset.tab, location);
  });

  document.getElementById("sign-out-btn").addEventListener("click", signOut);

  renderTab(TABS[0], location);
}

function renderTab(tab, location) {
  if (tab === "dashboard") return renderDashboardTab(location);
  if (tab === "ingredients") return renderIngredientsTab(location);
  return renderTabStub(tab);
}

function renderTabStub(tab) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  const label = tab.charAt(0).toUpperCase() + tab.slice(1);
  content.innerHTML = `
    <div class="empty-state">
      <h3>${escapeHtml(label)}</h3>
      <p>Coming in Task 6.</p>
    </div>`;
}

// ---------------------------------------------------------------------
// DASHBOARD -- GET /locations/{loc}/dashboard
// ---------------------------------------------------------------------
async function renderDashboardTab(location) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  content.innerHTML = `<p class="subtle">Loading dashboard…</p>`;

  let d;
  try {
    d = await api(`/locations/${location.id}/dashboard`);
  } catch (e) {
    content.innerHTML = `<div class="empty-state"><h3>Couldn't load the dashboard</h3><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }

  const nameEl = document.getElementById("restaurant-name");
  if (nameEl) nameEl.textContent = d.location.name;

  const s = d.summary;
  const summaryStrip = `
    <div class="summary-strip">
      <div class="card"><div class="num">${escapeHtml(String(s.total_alerts))}</div><div class="lbl">Active alerts</div></div>
      <div class="card"><div class="num">${escapeHtml(pct(s.avg_fc_pct))}</div><div class="lbl">Avg food cost</div></div>
      <div class="card"><div class="num">${escapeHtml(String(s.ok_count))}</div><div class="lbl">On target</div></div>
      <div class="card"><div class="num">${escapeHtml(String(s.watch_count))}</div><div class="lbl">Watch</div></div>
      <div class="card"><div class="num">${escapeHtml(String(s.danger_count))}</div><div class="lbl">Over target</div></div>
      <div class="card"><div class="num">${escapeHtml(String(s.incomplete_count))}</div><div class="lbl">Incomplete</div></div>
    </div>`;

  let alertsHtml;
  if (d.alerts.length === 0) {
    alertsHtml = `<div class="empty-state"><h3>No price drift right now</h3><p>Once an ingredient's latest price moves ${escapeHtml(pct(s.drift_threshold_pct))} or more from its trailing 90-day average, it'll show up here.</p></div>`;
  } else {
    alertsHtml = `<div class="grid grid-cards">` + d.alerts.map((a) => `
      <div class="alert-card">
        <div class="name">${escapeHtml(a.name)}</div>
        <div class="drift">${escapeHtml(signedPct(a.drift_pct))}</div>
        <div class="meta">${escapeHtml(money(a.trailing_avg))} avg &rarr; ${escapeHtml(money(a.latest_price))} now &middot; ${escapeHtml(a.vendor || "")}</div>
      </div>`).join("") + `</div>`;
  }

  let moversHtml;
  if (d.top_movers.length === 0) {
    moversHtml = `<p class="subtle">No purchase history yet.</p>`;
  } else {
    const widths = barWidths(d.top_movers);
    moversHtml = d.top_movers.map((m, idx) => {
      const dir = m.direction === "up" ? "up" : "down";
      const color = dir === "up" ? "var(--paprika)" : "var(--teal)";
      return `
      <div class="movers-bar-row">
        <div class="movers-name">${escapeHtml(m.name)}</div>
        <div class="movers-track"><div class="movers-fill ${dir}" style="width:${widths[idx]}px;"></div></div>
        <div class="movers-pct" style="color:${color}">${escapeHtml(signedPct(m.drift_pct))}</div>
      </div>`;
    }).join("");
  }

  let menuHtml;
  if (d.menu_items.length === 0) {
    menuHtml = `<div class="empty-state"><h3>No recipes yet</h3><p>Add a recipe on the Recipes tab to see plate cost and food-cost % here.</p></div>`;
  } else {
    menuHtml = `<div class="table-scroll"><table>
      <thead><tr><th>Item</th><th>Plate cost</th><th>Menu price</th><th>Food cost %</th><th>Status</th><th>Suggested price</th></tr></thead>
      <tbody>${d.menu_items.map((m) => {
        const status = m.status || "incomplete";
        return `
        <tr>
          <td>${escapeHtml(m.name)}</td>
          <td>${escapeHtml(money(m.plate_cost))}</td>
          <td>${escapeHtml(money(m.menu_price))}</td>
          <td>${escapeHtml(pct(m.fc_pct))}</td>
          <td><span class="chip chip-${escapeHtml(status)}">${escapeHtml(status)}</span></td>
          <td>${escapeHtml(money(m.suggested_price))}</td>
        </tr>`;
      }).join("")}</tbody>
    </table></div>`;
  }

  content.innerHTML = `
    ${summaryStrip}
    <div class="section-header"><h2>Drift alerts</h2></div>
    ${alertsHtml}
    <div class="two-col">
      <div>
        <div class="section-header"><h2>Menu items</h2></div>
        <div class="card">${menuHtml}</div>
      </div>
      <div>
        <div class="section-header"><h2>Top price movers</h2></div>
        <div class="card">${moversHtml}</div>
      </div>
    </div>`;
}

// ---------------------------------------------------------------------
// INGREDIENTS -- GET/DELETE /locations/{loc}/ingredients[/...], quick
// purchase entry (resolve-or-create against the new no-auto-create API).
// ---------------------------------------------------------------------
async function renderIngredientsTab(location) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  content.innerHTML = `<p class="subtle">Loading ingredients…</p>`;

  let ingredients;
  try {
    ingredients = await api(`/locations/${location.id}/ingredients`);
  } catch (e) {
    content.innerHTML = `<div class="empty-state"><h3>Couldn't load ingredients</h3><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }

  const rows = ingredients.map((i) => `
    <tr data-id="${escapeHtml(i.id)}">
      <td>${escapeHtml(i.name)}</td>
      <td>${escapeHtml(i.category || "—")}</td>
      <td>${escapeHtml(i.vendor || "—")}</td>
      <td>${escapeHtml(i.base_unit)}</td>
      <td>${i.latest_price !== null ? escapeHtml(money(i.latest_price)) + "/" + escapeHtml(i.base_unit) : "—"}</td>
      <td>${escapeHtml(String(i.purchase_count))}</td>
      <td><button class="btn btn-danger btn-sm" type="button" data-delete-id="${escapeHtml(i.id)}">Delete</button></td>
    </tr>`).join("");

  const table = ingredients.length ? `
    <div class="table-scroll"><table>
      <thead><tr><th>Name</th><th>Category</th><th>Vendor</th><th>Unit</th><th>Latest price</th><th>Purchases</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>` : `<div class="empty-state"><h3>No ingredients yet</h3><p>Add your first purchase below to get started.</p></div>`;

  content.innerHTML = `
    <div class="section-header"><h2>Ingredients</h2></div>
    <div class="card">${table}</div>
    <div id="ingredient-detail"></div>

    <div class="section-header"><h2>Quick-entry purchase</h2></div>
    <div class="card">
      <form id="purchase-form" class="entry-form">
        <div class="field" style="grid-column: span 2;">
          <label>Ingredient name</label>
          <input type="text" id="p-name" list="ingredient-names" placeholder="e.g. chicken breast" required autocomplete="off">
          <datalist id="ingredient-names">
            ${ingredients.map((i) => `<option value="${escapeHtml(i.name)}">`).join("")}
          </datalist>
          <div id="match-hint"></div>
        </div>
        <div class="field">
          <label>Vendor (if new)</label>
          <input type="text" id="p-vendor" placeholder="Sysco">
        </div>
        <div class="field">
          <label>Category (if new)</label>
          <input type="text" id="p-category" placeholder="Produce">
        </div>
        <div class="field">
          <label>Base unit (if new)</label>
          <select id="p-base-unit">
            <option value="each">each</option>
            <option value="lb">lb</option>
            <option value="oz">oz</option>
            <option value="kg">kg</option>
            <option value="g">g</option>
          </select>
        </div>
        <div class="field">
          <label>Date</label>
          <input type="date" id="p-date" value="${escapeHtml(todayLocalISO())}" required>
        </div>
        <div class="field">
          <label>Qty</label>
          <input type="number" id="p-qty" step="0.01" min="0.01" required>
        </div>
        <div class="field">
          <label>Unit</label>
          <select id="p-unit">
            <option value="each">each</option>
            <option value="lb">lb</option>
            <option value="oz">oz</option>
            <option value="kg">kg</option>
            <option value="g">g</option>
            <option value="case">case</option>
          </select>
        </div>
        <div class="field" id="qty-in-case-field" style="display:none;">
          <label>Units per case</label>
          <input type="number" id="p-qty-in-case" step="0.01" min="0.01">
        </div>
        <div class="field">
          <label>Total price paid</label>
          <input type="number" id="p-total" step="0.01" min="0.01" required>
        </div>
        <div class="field">
          <button class="btn" type="submit">Save purchase</button>
        </div>
      </form>
    </div>`;

  document.getElementById("p-unit").addEventListener("change", (e) => {
    document.getElementById("qty-in-case-field").style.display = e.target.value === "case" ? "flex" : "none";
  });

  let matchDebounce = null;
  document.getElementById("p-name").addEventListener("input", (e) => {
    clearTimeout(matchDebounce);
    const name = e.target.value.trim();
    const hint = document.getElementById("match-hint");
    if (!name) { hint.innerHTML = ""; return; }
    matchDebounce = setTimeout(async () => {
      let r;
      try {
        r = await api(`/locations/${location.id}/ingredients/match?name=${encodeURIComponent(name)}`);
      } catch (e2) {
        return; // best-effort hint only -- submit re-resolves for real
      }
      if (r.match) {
        hint.innerHTML = `<div class="match-hint">Looks like <strong>${escapeHtml(r.match.name)}</strong> — we'll link this purchase to it instead of creating a duplicate.</div>`;
      } else {
        hint.innerHTML = `<div class="match-hint">New ingredient — it'll be created using the vendor/category/unit fields.</div>`;
      }
    }, 300);
  });

  document.getElementById("purchase-form").addEventListener("submit", (e) => handlePurchaseSubmit(e, location));

  content.querySelectorAll("tbody tr[data-id]").forEach((tr) => {
    tr.addEventListener("click", (e) => {
      if (e.target.closest("[data-delete-id]")) return;
      showIngredientDetail(tr.dataset.id, location);
    });
  });

  content.querySelectorAll("[data-delete-id]").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      deleteIngredient(btn.dataset.deleteId, location);
    });
  });
}

async function deleteIngredient(id, location) {
  try {
    await api(`/locations/${location.id}/ingredients/${id}`, { method: "DELETE" });
    toast("Ingredient deleted.");
    renderIngredientsTab(location);
  } catch (e) {
    toast("Couldn't delete ingredient: " + errorMessage(e), true);
  }
}

async function showIngredientDetail(id, location) {
  const container = document.getElementById("ingredient-detail");
  if (!container) return;
  container.innerHTML = `<p class="subtle">Loading history…</p>`;

  let data;
  try {
    data = await api(`/locations/${location.id}/ingredients/${id}/history`);
  } catch (e) {
    container.innerHTML = `<div class="empty-state"><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }

  const purchases = data.purchases; // DESC, as returned
  container.innerHTML = `
    <div class="card">
      <div class="section-header">
        <h3>Purchase history</h3>
        <span class="subtle">${escapeHtml(String(purchases.length))} purchase${purchases.length === 1 ? "" : "s"}</span>
      </div>
      <canvas class="spark" id="spark-canvas"></canvas>
      <div class="table-scroll" style="margin-top:12px;">
        <table>
          <thead><tr><th>Date</th><th>Qty (base units)</th><th>Total</th><th>Unit price</th><th>Source</th><th></th></tr></thead>
          <tbody>${purchases.map((p) => `
            <tr>
              <td>${escapeHtml(p.purchased_on)}</td>
              <td>${escapeHtml(p.qty_base_units)}</td>
              <td>${escapeHtml(money(p.total_price))}</td>
              <td>${escapeHtml(money(p.unit_price))}</td>
              <td>${escapeHtml(p.source)}</td>
              <td><button class="btn btn-danger btn-sm" type="button" data-purchase-delete-id="${escapeHtml(p.id)}">Delete</button></td>
            </tr>`).join("")}</tbody>
        </table>
      </div>
    </div>`;

  drawSparkline(document.getElementById("spark-canvas"), purchases);

  container.querySelectorAll("[data-purchase-delete-id]").forEach((btn) => {
    btn.addEventListener("click", () => deletePurchase(btn.dataset.purchaseDeleteId, id, location));
  });
}

async function deletePurchase(purchaseId, ingredientId, location) {
  try {
    await api(`/locations/${location.id}/purchases/${purchaseId}`, { method: "DELETE" });
    toast("Purchase deleted.");
  } catch (e) {
    toast("Couldn't delete purchase: " + errorMessage(e), true);
    return;
  }
  await renderIngredientsTab(location);
  showIngredientDetail(ingredientId, location);
}

// drawSparkline -- canvas rendering only; all coordinate math (including
// Number(unit_price)) lives in lib.mjs::sparklinePoints.
function drawSparkline(canvas, purchasesDesc) {
  if (!canvas) return;
  const purchasesAsc = purchasesDesc.slice().reverse();
  if (purchasesAsc.length === 0) return;

  const dpr = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  const w = Math.max(rect.width, 300);
  const h = 140;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, w, h);

  const points = sparklinePoints(purchasesAsc, w, h);
  if (points.length === 0) return;

  ctx.strokeStyle = "#0F5E63";
  ctx.lineWidth = 2;
  ctx.beginPath();
  points.forEach((p, idx) => {
    if (idx === 0) ctx.moveTo(p.x, p.y); else ctx.lineTo(p.x, p.y);
  });
  ctx.stroke();

  ctx.fillStyle = "#E8A33D";
  points.forEach((p, idx) => {
    ctx.beginPath();
    ctx.arc(p.x, p.y, idx === points.length - 1 ? 4 : 2.5, 0, Math.PI * 2);
    ctx.fill();
  });
}

// handlePurchaseSubmit -- the new API never auto-creates an ingredient:
// resolve the typed name against /ingredients/match first; if nothing
// matches, create it (adopting matches[0].id on a 409 duplicate race);
// only then POST the purchase against a real ingredient_id.
async function handlePurchaseSubmit(e, location) {
  e.preventDefault();
  const name = document.getElementById("p-name").value.trim();
  if (!name) return;
  const unit = document.getElementById("p-unit").value;
  const rawForm = {
    purchased_on: document.getElementById("p-date").value,
    qty: document.getElementById("p-qty").value,
    unit,
    total_price: document.getElementById("p-total").value,
    qty_in_case: unit === "case" ? document.getElementById("p-qty-in-case").value : "",
  };

  try {
    const ingredientId = await resolveIngredientId(name, location);
    const payload = buildPurchasePayload({ ...rawForm, ingredient_id: ingredientId });
    const r = await api(`/locations/${location.id}/purchases`, { method: "POST", body: payload });
    toast(`Saved purchase @ ${money(r.unit_price)}/${unit}.`);
    await renderIngredientsTab(location);
  } catch (err) {
    toast("Couldn't save purchase: " + errorMessage(err), true);
  }
}

async function resolveIngredientId(name, location) {
  const m = await api(`/locations/${location.id}/ingredients/match?name=${encodeURIComponent(name)}`);
  if (m.match) return m.match.id;

  const vendor = document.getElementById("p-vendor").value.trim() || null;
  const category = document.getElementById("p-category").value.trim() || null;
  const baseUnit = document.getElementById("p-base-unit").value;
  try {
    const created = await api(`/locations/${location.id}/ingredients`, {
      method: "POST",
      body: { name, base_unit: baseUnit, vendor, category },
    });
    return created.id;
  } catch (err) {
    if (err instanceof ApiError && err.status === 409 && err.detail
        && Array.isArray(err.detail.matches) && err.detail.matches[0]) {
      return err.detail.matches[0].id;
    }
    throw err;
  }
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
