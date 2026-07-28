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
  pickDefaultMembership, money, pct, signedPct, todayLocalISO, centsFromString,
  barWidths, sparklinePoints, buildPurchasePayload,
  buildRecipePayload, previewCost, buildSettingsPayload, validateRecipeLines,
  moneyFromCents,
} from "./lib.mjs";
import { fcStatus, suggestedPriceCents } from "/shared/kernel.js";

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
  if (tab === "recipes") return renderRecipesTab(location);
  if (tab === "import") return renderImportTab(location);
  if (tab === "settings") return renderSettingsTab(location);
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

// ---------------------------------------------------------------------
// RECIPES -- GET/POST/PUT/DELETE /locations/{loc}/recipes[/...]. The
// editor carries each line's item `id` (recipe_items.id) end-to-end and
// never drops it on save -- the client half of the double-plate-cost bug:
// the legacy editor (product/static/js/app.js:469) rebuilt its rows from
// {ingredient_id, qty_base_units} only, so every save re-inserted every
// line instead of updating in place. The live preview is the B3-JS fix:
// exact BigInt-rational cost (lib.mjs::previewCost) feeding
// shared/kernel.js's fcStatus/suggestedPriceCents, not legacy float math.
// ---------------------------------------------------------------------
let recipeEditItems = []; // [{id, ingredient_id, qty_base_units}], in DOM order

async function renderRecipesTab(location, editingRecipe) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  content.innerHTML = `<p class="subtle">Loading recipes…</p>`;

  let recipes, ingredients;
  try {
    [recipes, ingredients] = await Promise.all([
      api(`/locations/${location.id}/recipes`),
      api(`/locations/${location.id}/ingredients`),
    ]);
  } catch (e) {
    content.innerHTML = `<div class="empty-state"><h3>Couldn't load recipes</h3><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }

  const priceIndex = {};
  ingredients.forEach((i) => { priceIndex[i.id] = i.latest_price; });

  const listHtml = recipes.length ? `
    <div class="table-scroll"><table>
      <thead><tr><th>Recipe</th><th>Plate cost</th><th>Menu price</th><th>FC%</th><th>Status</th><th>Suggested</th><th></th></tr></thead>
      <tbody>${recipes.map((r) => {
        const status = r.status || "incomplete";
        return `
        <tr>
          <td>${escapeHtml(r.name)}</td>
          <td>${escapeHtml(money(r.plate_cost))}</td>
          <td>${escapeHtml(money(r.menu_price))}</td>
          <td>${escapeHtml(pct(r.fc_pct))}</td>
          <td><span class="chip chip-${escapeHtml(status)}">${escapeHtml(status)}</span></td>
          <td>${escapeHtml(money(r.suggested_price))}</td>
          <td>
            <button class="btn btn-secondary btn-sm" type="button" data-edit-recipe="${escapeHtml(r.recipe_id)}">Edit</button>
            <button class="btn btn-danger btn-sm" type="button" data-delete-recipe="${escapeHtml(r.recipe_id)}">Delete</button>
          </td>
        </tr>`;
      }).join("")}</tbody>
    </table></div>` : `<div class="empty-state"><h3>No recipes yet</h3><p>Build your first one below.</p></div>`;

  const editing = editingRecipe || null;
  // `name`/`base_unit` are carried along for existing lines only, so
  // drawRecipeItems can render them as fixed text without a second lookup
  // (and it still works for a tombstoned ingredient, since the server's
  // LEFT JOIN keeps returning its name/base_unit after a soft delete).
  recipeEditItems = editing
    ? editing.items.map((it) => ({
        id: it.id, ingredient_id: it.ingredient_id, qty_base_units: it.qty_base_units,
        name: it.name, base_unit: it.base_unit,
      }))
    : [{ id: null, ingredient_id: ingredients[0] ? ingredients[0].id : "", qty_base_units: "1" }];

  content.innerHTML = `
    <div class="section-header"><h2>Recipes</h2></div>
    <div class="card">${listHtml}</div>

    <div class="section-header"><h2>${editing ? "Edit recipe" : "Build a recipe"}</h2></div>
    <div class="card">
      <form id="recipe-form">
        <div class="entry-form" style="margin-bottom:12px;">
          <div class="field">
            <label>Name</label>
            <input type="text" id="r-name" value="${editing ? escapeHtml(editing.name) : ""}" required>
          </div>
          <div class="field">
            <label>Menu price</label>
            <input type="number" id="r-menu-price" step="0.01" min="0.01" value="${editing ? escapeHtml(editing.menu_price) : ""}" required>
          </div>
          <div class="field">
            <label>Target food cost %</label>
            <input type="number" id="r-target" step="0.1" min="0.1" value="${editing ? escapeHtml(editing.target_fc_pct) : "30"}" required>
          </div>
        </div>

        <div id="recipe-items"></div>
        <button type="button" class="btn btn-secondary btn-sm" id="add-item">+ Add ingredient</button>

        <div class="recipe-summary" id="recipe-preview"></div>

        <button class="btn" type="submit">${editing ? "Save changes" : "Create recipe"}</button>
        ${editing ? `<button type="button" class="btn btn-secondary" id="cancel-edit">Cancel</button>` : ""}
      </form>
    </div>`;

  content.querySelectorAll("[data-edit-recipe]").forEach((b) => {
    b.addEventListener("click", () => {
      const r = recipes.find((x) => x.recipe_id === b.dataset.editRecipe);
      if (r) renderRecipesTab(location, r);
    });
  });
  content.querySelectorAll("[data-delete-recipe]").forEach((b) => {
    b.addEventListener("click", () => deleteRecipe(b.dataset.deleteRecipe, location));
  });
  if (editing) {
    document.getElementById("cancel-edit").addEventListener("click", () => renderRecipesTab(location));
  }

  document.getElementById("add-item").addEventListener("click", () => {
    recipeEditItems.push({ id: null, ingredient_id: ingredients[0] ? ingredients[0].id : "", qty_base_units: "1" });
    drawRecipeItems(ingredients, priceIndex);
  });

  document.getElementById("r-menu-price").addEventListener("input", () => updateRecipePreview(priceIndex));
  document.getElementById("r-target").addEventListener("input", () => updateRecipePreview(priceIndex));
  document.getElementById("recipe-form").addEventListener("submit", (e) => handleRecipeSubmit(e, location, editing));

  drawRecipeItems(ingredients, priceIndex);
}

// drawRecipeItems -- redraws the ingredient/qty rows from recipeEditItems
// and rewires their listeners.
//
// An EXISTING line (row.id set) renders its ingredient as fixed, escaped
// text, not a <select>: the server's update-by-id only ever updates a
// line's qty, so an edited ingredient_id on an existing line would be
// silently reverted the moment the save round-trips and the editor
// re-renders from the fresh server response -- repointing an ingredient
// is deliberately not a line edit (that's the merge endpoint's job). To
// change an existing line's ingredient, the user removes it and adds a
// new line instead, which the payload semantics already handle correctly
// (tombstone the old id, insert the new id-less line).
//
// A NEW line (row.id null/undefined) gets the live <select>. A row whose
// ingredient_id isn't in the live `ingredients` list (a tombstoned
// ingredient still on an existing recipe line) shows its carried-along
// name/base_unit as fixed text too, or "Unavailable ingredient" if even
// that's missing -- it stays excluded from priceIndex either way, so the
// preview correctly treats it as unresolvable.
function drawRecipeItems(ingredients, priceIndex) {
  const el = document.getElementById("recipe-items");
  if (!el) return;
  el.innerHTML = recipeEditItems.map((row) => {
    const isExisting = row.id !== null && row.id !== undefined;
    let ingredientCell;
    if (isExisting) {
      const label = row.name ? `${row.name} (${row.base_unit || ""})` : "Unavailable ingredient";
      ingredientCell = `<span class="ri-ingredient-fixed">${escapeHtml(label)}</span>`;
    } else {
      const known = ingredients.some((i) => i.id === row.ingredient_id);
      const unavailableOption = known ? "" :
        `<option value="${escapeHtml(row.ingredient_id)}" selected>Unavailable ingredient</option>`;
      ingredientCell = `
        <select class="ri-ingredient">
          ${unavailableOption}
          ${ingredients.map((i) => `<option value="${escapeHtml(i.id)}" ${i.id === row.ingredient_id ? "selected" : ""}>${escapeHtml(i.name)} (${escapeHtml(i.base_unit)})</option>`).join("")}
        </select>`;
    }
    return `
      <div class="recipe-item-row">
        ${ingredientCell}
        <input type="text" class="ri-qty" value="${escapeHtml(row.qty_base_units)}" inputmode="decimal" placeholder="qty" required>
        <button type="button" class="btn btn-danger btn-sm ri-remove">✕</button>
      </div>`;
  }).join("");

  Array.from(el.querySelectorAll(".recipe-item-row")).forEach((rowEl, idx) => {
    const ingredientSelect = rowEl.querySelector(".ri-ingredient");
    if (ingredientSelect) {
      ingredientSelect.addEventListener("change", (e) => {
        recipeEditItems[idx].ingredient_id = e.target.value;
        updateRecipePreview(priceIndex);
      });
    }
    rowEl.querySelector(".ri-qty").addEventListener("input", (e) => {
      recipeEditItems[idx].qty_base_units = e.target.value;
      updateRecipePreview(priceIndex);
    });
    rowEl.querySelector(".ri-remove").addEventListener("click", () => {
      recipeEditItems.splice(idx, 1);
      drawRecipeItems(ingredients, priceIndex);
    });
  });

  updateRecipePreview(priceIndex);
}

// updateRecipePreview -- the exact live preview (B3-JS fix). previewCost
// sums every line's qty * unit_price as BigInt rationals and rounds to
// cents exactly once; the resulting cents feed straight into
// shared/kernel.js's fcStatus/suggestedPriceCents, so this always matches
// what the server would compute for the same inputs. Never throws into
// the caller: any parse failure (mid-edit qty, empty menu price, ...)
// degrades to dashes, never NaN.
function updateRecipePreview(priceIndex) {
  const preview = document.getElementById("recipe-preview");
  if (!preview) return;

  let plateCents = null, complete = true;
  try {
    ({ cents: plateCents, complete } = previewCost(recipeEditItems, priceIndex));
  } catch (e) {
    // an unparsable qty/price mid-edit -- show dashes, don't crash, and
    // flag incomplete too (a thrown preview is exactly as unknown as an
    // excluded line, and the banner should say so either way).
    plateCents = null;
    complete = false;
  }

  const menuPriceStr = document.getElementById("r-menu-price").value.trim();
  const targetStr = document.getElementById("r-target").value.trim();

  let fcCell = "—";
  let statusHtml = `<span class="chip chip-incomplete">incomplete</span>`;
  let suggestedCell = "—";

  if (plateCents !== null && complete) {
    try {
      const menuCents = menuPriceStr ? centsFromString(menuPriceStr) : 0;
      const targetBp = targetStr ? centsFromString(targetStr) : 0;
      if (menuCents > 0 && targetBp > 0) {
        const result = fcStatus(plateCents, menuCents, targetBp);
        const suggested = suggestedPriceCents(plateCents, targetBp);
        fcCell = pct(result.fc);
        statusHtml = `<span class="chip chip-${escapeHtml(result.status)}">${escapeHtml(result.status)}</span>`;
        suggestedCell = money(moneyFromCents(suggested));
      }
    } catch (e) {
      // invalid/incomplete menu price or target mid-edit -- leave dashes
    }
  }

  preview.innerHTML = `
    <div class="stat"><div class="num">${escapeHtml(plateCents === null ? "—" : money(moneyFromCents(plateCents)))}</div><div class="lbl">Plate cost</div></div>
    <div class="stat"><div class="num">${escapeHtml(fcCell)}</div><div class="lbl">Food cost %</div></div>
    <div class="stat"><div class="num">${statusHtml}</div><div class="lbl">Status</div></div>
    <div class="stat"><div class="num">${escapeHtml(suggestedCell)}</div><div class="lbl">Suggested price</div></div>
    ${!complete ? `<div class="stat" style="grid-column:1/-1;"><span class="subtle">Preview incomplete — one or more ingredients don't have a price yet.</span></div>` : ""}
  `;
}

async function handleRecipeSubmit(e, location, editing) {
  e.preventDefault();

  // validateRecipeLines is the belt-and-braces layer behind the .ri-qty
  // `required` attribute: a blank qty on an EXISTING line must never be
  // silently filtered out of the payload -- the server diffs by id, so a
  // dropped line is indistinguishable from "the user removed it" and gets
  // tombstoned with no error at all. Only a never-filled id-less add-row
  // is silently skipped; anything else with a blank qty aborts the save.
  const validation = validateRecipeLines(recipeEditItems);
  if (!validation.ok) {
    toast(validation.error, true);
    return;
  }

  const editingState = {
    name: document.getElementById("r-name").value.trim(),
    menu_price: document.getElementById("r-menu-price").value.trim(),
    target_fc_pct: document.getElementById("r-target").value.trim(),
    items: validation.lines,
  };
  if (editingState.items.length === 0) {
    toast("Add at least one ingredient.", true);
    return;
  }

  const isCreate = !editing;
  const payload = buildRecipePayload(editingState, isCreate);
  try {
    if (editing) {
      await api(`/locations/${location.id}/recipes/${editing.recipe_id}`, { method: "PUT", body: payload });
      toast("Recipe updated.");
    } else {
      await api(`/locations/${location.id}/recipes`, { method: "POST", body: payload });
      toast("Recipe created.");
    }
    renderRecipesTab(location);
  } catch (err) {
    toast("Couldn't save recipe: " + errorMessage(err), true);
  }
}

async function deleteRecipe(id, location) {
  try {
    await api(`/locations/${location.id}/recipes/${id}`, { method: "DELETE" });
    toast("Recipe deleted.");
    renderRecipesTab(location);
  } catch (e) {
    toast("Couldn't delete recipe: " + errorMessage(e), true);
  }
}

// ---------------------------------------------------------------------
// IMPORT -- CSV only. No invoice photo upload/list/attach in this client
// (the legacy invoice-photo flow and invoice_id attach are dropped
// entirely, per the frozen contract -- purchases carry no invoice_id).
// ---------------------------------------------------------------------
async function renderImportTab(location) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  content.innerHTML = `
    <div class="section-header"><h2>Import purchases</h2></div>
    <div class="card">
      <p class="subtle">Paste or upload a CSV with columns: <code>item,vendor,date,qty,unit,total</code></p>
      <form id="csv-form">
        <div class="field">
          <label>Paste CSV</label>
          <textarea id="csv-text" placeholder="item,vendor,date,qty,unit,total
chicken breast,Reinhart,2026-07-20,30,lb,102.50"></textarea>
        </div>
        <div class="field" style="margin-top:8px;">
          <label>...or upload a .csv file</label>
          <input type="file" id="csv-file" accept=".csv,text/csv">
        </div>
        <button class="btn" type="submit" style="margin-top:10px;">Import</button>
      </form>
      <div id="import-result"></div>
    </div>`;

  document.getElementById("csv-form").addEventListener("submit", (e) => handleImportSubmit(e, location));
}

async function handleImportSubmit(e, location) {
  e.preventDefault();
  const file = document.getElementById("csv-file").files[0];
  const text = document.getElementById("csv-text").value.trim();
  if (!file && !text) {
    toast("Paste some CSV or choose a file first.", true);
    return;
  }

  const fd = new FormData();
  if (file) {
    fd.append("file", file);
  } else {
    fd.append("csv_text", text);
  }

  let result;
  try {
    result = await api(`/locations/${location.id}/purchases/import`, { method: "POST", body: fd });
  } catch (err) {
    toast("Import failed: " + errorMessage(err), true);
    return;
  }

  const errHtml = result.errors.length
    ? `<p style="color:var(--paprika)">${escapeHtml(String(result.errors.length))} row(s) had errors: ${result.errors.map((er) => `row ${escapeHtml(String(er.row))}: ${escapeHtml(er.error)}`).join("; ")}</p>`
    : "";
  document.getElementById("import-result").innerHTML = `
    <div class="match-hint" style="margin-top:10px;">
      Processed ${escapeHtml(String(result.rows_processed))} row(s): ${escapeHtml(String(result.created))} new ingredient(s), ${escapeHtml(String(result.matched))} matched to existing.
    </div>${errHtml}`;
  toast(`Imported ${result.rows_processed} row(s).`);
}

// ---------------------------------------------------------------------
// SETTINGS -- current location's row from GET /orgs/{org}/locations;
// PATCH /locations/{loc} via buildSettingsPayload. 403 (non-owner/manager)
// gets a fixed, specific toast rather than the raw server detail.
// ---------------------------------------------------------------------
async function renderSettingsTab(location) {
  const content = document.getElementById("tab-content");
  if (!content) return;
  content.innerHTML = `<p class="subtle">Loading settings…</p>`;

  const ctx = getCtx();
  let locations;
  try {
    locations = await api(`/orgs/${ctx.org_id}/locations`);
  } catch (e) {
    content.innerHTML = `<div class="empty-state"><h3>Couldn't load settings</h3><p>${escapeHtml(errorMessage(e))}</p></div>`;
    return;
  }
  const current = locations.find((l) => l.id === location.id);
  if (!current) {
    content.innerHTML = `<div class="empty-state"><h3>Couldn't load settings</h3><p>This location is no longer available.</p></div>`;
    return;
  }

  content.innerHTML = `
    <div class="section-header"><h2>Settings</h2></div>
    <div class="card" style="max-width:480px;">
      <form id="settings-form">
        <div class="field" style="margin-bottom:12px;">
          <label>Restaurant name</label>
          <input type="text" id="s-name" value="${escapeHtml(current.name)}">
        </div>
        <div class="field" style="margin-bottom:12px;">
          <label>Default target food cost % (new recipes)</label>
          <input type="number" id="s-target" step="0.1" min="0.1" value="${escapeHtml(current.target_fc_pct)}">
        </div>
        <div class="field" style="margin-bottom:12px;">
          <label>Drift alert threshold %</label>
          <input type="number" id="s-threshold" step="0.1" min="0.1" value="${escapeHtml(current.drift_threshold_pct)}">
        </div>
        <button class="btn" type="submit">Save settings</button>
      </form>
    </div>`;

  document.getElementById("settings-form").addEventListener("submit", (e) => handleSettingsSubmit(e, location, current));
}

async function handleSettingsSubmit(e, location, current) {
  e.preventDefault();
  const form = {
    name: document.getElementById("s-name").value.trim(),
    target_fc_pct: document.getElementById("s-target").value.trim(),
    drift_threshold_pct: document.getElementById("s-threshold").value.trim(),
  };
  const payload = buildSettingsPayload(form, current);
  if (!payload) {
    toast("Nothing changed.");
    return;
  }

  let updated;
  try {
    updated = await api(`/locations/${location.id}`, { method: "PATCH", body: payload });
  } catch (err) {
    if (err instanceof ApiError && err.status === 403) {
      toast("owner or manager required", true);
    } else {
      toast("Couldn't save settings: " + errorMessage(err), true);
    }
    return;
  }

  toast("Settings saved.");
  // Update the topbar and the in-memory location object shared across tabs
  // (the cached ctx) so switching tabs afterward keeps showing the new name.
  location.name = updated.name;
  location.target_fc_pct = updated.target_fc_pct;
  location.drift_threshold_pct = updated.drift_threshold_pct;
  const nameEl = document.getElementById("restaurant-name");
  if (nameEl) nameEl.textContent = updated.name;
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
