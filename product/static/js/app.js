// CostSauce SPA — vanilla JS, no build step.
(() => {
  "use strict";

  const app = document.getElementById("app");
  const toastEl = document.getElementById("toast");
  let toastTimer = null;

  const state = {
    tab: "dashboard",
    ingredients: [],       // cache, refreshed per-tab load
    invoices: [],
  };

  // ---------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------
  function escapeHtml(s) {
    if (s === null || s === undefined) return "";
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function money(n) {
    if (n === null || n === undefined || isNaN(n)) return "—";
    return "$" + Number(n).toFixed(2);
  }

  function pct(n) {
    if (n === null || n === undefined || isNaN(n)) return "—";
    const sign = n > 0 ? "+" : "";
    return sign + Number(n).toFixed(1) + "%";
  }

  function toast(msg, isError) {
    toastEl.textContent = msg;
    toastEl.className = "toast show" + (isError ? " error" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toastEl.className = "toast";
    }, 3800);
  }

  async function api(path, opts) {
    opts = opts || {};
    const headers = opts.headers || {};
    let body = opts.body;
    if (body && !(body instanceof FormData)) {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(body);
    }
    const res = await fetch(path, { method: opts.method || "GET", headers, body });
    let data = null;
    try {
      data = await res.json();
    } catch (e) {
      data = null;
    }
    if (!res.ok) {
      const detail = data && data.detail;
      const msg = typeof detail === "string" ? detail : (detail && detail.message) || (data && data.message) || res.statusText;
      const err = new Error(msg);
      err.data = data;
      err.status = res.status;
      throw err;
    }
    return data;
  }

  function driftColor(n) {
    if (n === null || n === undefined) return "";
    return n > 0 ? "up" : "down";
  }

  function todayISO() {
    const d = new Date();
    return d.toISOString().slice(0, 10);
  }

  // ---------------------------------------------------------------------
  // tab routing
  // ---------------------------------------------------------------------
  document.getElementById("tabs").addEventListener("click", (e) => {
    const btn = e.target.closest(".tab-btn");
    if (!btn) return;
    switchTab(btn.dataset.tab);
  });

  function switchTab(tab) {
    state.tab = tab;
    document.querySelectorAll(".tab-btn").forEach((b) => {
      b.classList.toggle("active", b.dataset.tab === tab);
    });
    render();
  }

  function render() {
    if (state.tab === "dashboard") return renderDashboard();
    if (state.tab === "ingredients") return renderIngredients();
    if (state.tab === "recipes") return renderRecipes();
    if (state.tab === "import") return renderImport();
    if (state.tab === "settings") return renderSettings();
  }

  // ---------------------------------------------------------------------
  // DASHBOARD
  // ---------------------------------------------------------------------
  async function renderDashboard() {
    app.innerHTML = `<p class="subtle">Loading dashboard…</p>`;
    let d;
    try {
      d = await api("/api/dashboard");
    } catch (e) {
      app.innerHTML = `<div class="empty-state"><h3>Couldn't load the dashboard</h3><p>${escapeHtml(e.message)}</p></div>`;
      return;
    }
    document.getElementById("restaurant-name").textContent = d.restaurant;

    const s = d.summary;
    const summaryStrip = `
      <div class="summary-strip">
        <div class="card"><div class="num">${s.total_alerts}</div><div class="lbl">Active alerts</div></div>
        <div class="card"><div class="num">${s.avg_fc_pct.toFixed(1)}%</div><div class="lbl">Avg food cost</div></div>
        <div class="card"><div class="num">${s.ok_count}</div><div class="lbl">On target</div></div>
        <div class="card"><div class="num">${s.watch_count}</div><div class="lbl">Watch</div></div>
        <div class="card"><div class="num">${s.danger_count}</div><div class="lbl">Over target</div></div>
      </div>`;

    let alertsHtml;
    if (d.alerts.length === 0) {
      alertsHtml = `<div class="empty-state"><h3>No price drift right now</h3><p>Once an ingredient's latest price moves ${d.summary.drift_threshold_pct}% or more from its trailing 90-day average, it'll show up here.</p></div>`;
    } else {
      alertsHtml = `<div class="grid grid-cards">` + d.alerts.map((a) => `
        <div class="alert-card">
          <div class="name">${escapeHtml(a.name)}</div>
          <div class="drift">${pct(a.drift_pct)}</div>
          <div class="meta">${money(a.trailing_avg)}/${a.name.includes("each") ? "" : ""} avg &rarr; ${money(a.latest_price)} now &middot; ${escapeHtml(a.vendor || "")}</div>
        </div>`).join("") + `</div>`;
    }

    let moversHtml;
    if (d.top_movers.length === 0) {
      moversHtml = `<p class="subtle">No purchase history yet.</p>`;
    } else {
      const maxAbs = Math.max(...d.top_movers.map((m) => Math.abs(m.drift_pct)), 1);
      moversHtml = d.top_movers.map((m) => {
        const widthPct = Math.min(50, (Math.abs(m.drift_pct) / maxAbs) * 50);
        const dir = driftColor(m.drift_pct);
        const style = dir === "up"
          ? `left:50%; width:${widthPct}%;`
          : `left:${50 - widthPct}%; width:${widthPct}%;`;
        return `
        <div class="movers-bar-row">
          <div class="movers-name">${escapeHtml(m.name)}</div>
          <div class="movers-track"><div class="movers-fill ${dir}" style="${style}"></div></div>
          <div class="movers-pct" style="color:${dir === "up" ? "var(--paprika)" : "var(--teal)"}">${pct(m.drift_pct)}</div>
        </div>`;
      }).join("");
    }

    let menuHtml;
    if (d.menu_items.length === 0) {
      menuHtml = `<div class="empty-state"><h3>No recipes yet</h3><p>Add a recipe on the Recipes tab to see plate cost and food-cost % here.</p></div>`;
    } else {
      menuHtml = `<div class="table-scroll"><table>
        <thead><tr><th>Item</th><th>Plate cost</th><th>Menu price</th><th>Food cost %</th><th>Status</th><th>Suggested price</th></tr></thead>
        <tbody>${d.menu_items.map((m) => `
          <tr>
            <td>${escapeHtml(m.name)}</td>
            <td>${money(m.plate_cost)}</td>
            <td>${money(m.menu_price)}</td>
            <td>${m.fc_pct.toFixed(1)}%</td>
            <td><span class="chip chip-${m.status}">${m.status}</span></td>
            <td>${money(m.suggested_price)}</td>
          </tr>`).join("")}</tbody>
      </table></div>`;
    }

    app.innerHTML = `
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
  // INGREDIENTS
  // ---------------------------------------------------------------------
  async function renderIngredients(selectedId) {
    app.innerHTML = `<p class="subtle">Loading ingredients…</p>`;
    let ingredients, invoices;
    try {
      [ingredients, invoices] = await Promise.all([api("/api/ingredients"), api("/api/invoices")]);
    } catch (e) {
      app.innerHTML = `<div class="empty-state"><h3>Couldn't load ingredients</h3><p>${escapeHtml(e.message)}</p></div>`;
      return;
    }
    state.ingredients = ingredients;
    state.invoices = invoices;

    const rows = ingredients.map((i) => `
      <tr data-id="${i.id}">
        <td>${escapeHtml(i.name)}</td>
        <td>${escapeHtml(i.category || "—")}</td>
        <td>${escapeHtml(i.vendor || "—")}</td>
        <td>${escapeHtml(i.base_unit)}</td>
        <td>${i.latest_price !== null ? money(i.latest_price) + "/" + escapeHtml(i.base_unit) : "—"}</td>
        <td style="color:${i.drift_pct > 0 ? "var(--paprika)" : i.drift_pct < 0 ? "var(--teal)" : "inherit"}">${i.drift_pct !== null ? pct(i.drift_pct) : "—"}</td>
        <td>${i.purchase_count}</td>
      </tr>`).join("");

    const table = ingredients.length ? `
      <div class="table-scroll"><table>
        <thead><tr><th>Name</th><th>Category</th><th>Vendor</th><th>Unit</th><th>Latest price</th><th>Drift</th><th>Purchases</th></tr></thead>
        <tbody>${rows}</tbody>
      </table></div>` : `<div class="empty-state"><h3>No ingredients yet</h3><p>Add your first purchase below to get started.</p></div>`;

    const unresolvedInvoices = invoices.filter((iv) => iv.status === "manual");

    app.innerHTML = `
      <div class="section-header"><h2>Ingredients</h2></div>
      <div class="card">${table}</div>
      <div id="ingredient-detail"></div>

      <div class="section-header"><h2>Quick-entry purchase</h2></div>
      <div class="card">
        <form id="purchase-form" class="entry-form">
          <div class="field" style="grid-column: span 2;">
            <label>Ingredient name</label>
            <input type="text" id="p-name" list="ingredient-names" placeholder="e.g. chicken breast" required>
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
            </select>
          </div>
          <div class="field">
            <label>Date</label>
            <input type="date" id="p-date" value="${todayISO()}" required>
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
            <label>Attach invoice (optional)</label>
            <select id="p-invoice">
              <option value="">None</option>
              ${unresolvedInvoices.map((iv) => `<option value="${iv.id}">${escapeHtml(iv.filename)}</option>`).join("")}
            </select>
          </div>
          <div class="field">
            <button class="btn" type="submit">Save purchase</button>
          </div>
        </form>
      </div>
    `;

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
        try {
          const r = await api("/api/ingredients/match?name=" + encodeURIComponent(name));
          if (r.match) {
            hint.innerHTML = `<div class="match-hint">Looks like <strong>${escapeHtml(r.match.name)}</strong> — we'll link this purchase to it instead of creating a duplicate.</div>`;
          } else {
            hint.innerHTML = `<div class="match-hint">New ingredient — it'll be created using the vendor/category/unit fields.</div>`;
          }
        } catch (e2) { /* ignore */ }
      }, 300);
    });

    document.getElementById("purchase-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const unit = document.getElementById("p-unit").value;
      const payload = {
        ingredient_name: document.getElementById("p-name").value.trim(),
        vendor: document.getElementById("p-vendor").value.trim() || null,
        category: document.getElementById("p-category").value.trim() || null,
        base_unit: document.getElementById("p-base-unit").value,
        date: document.getElementById("p-date").value,
        qty: parseFloat(document.getElementById("p-qty").value),
        unit: unit,
        qty_in_case: unit === "case" ? parseFloat(document.getElementById("p-qty-in-case").value) : null,
        total_price: parseFloat(document.getElementById("p-total").value),
        source: "manual",
        invoice_id: document.getElementById("p-invoice").value || null,
      };
      try {
        const r = await api("/api/purchases", { method: "POST", body: payload });
        const driftMsg = r.drift_pct !== null ? ` Drift now ${pct(r.drift_pct)}.` : "";
        toast(`Saved: ${r.ingredient_name} @ ${money(r.unit_price)}/${r.unit}.${driftMsg}`);
        renderIngredients();
      } catch (err) {
        toast("Couldn't save purchase: " + err.message, true);
      }
    });

    document.querySelectorAll("#app tbody tr[data-id]").forEach((tr) => {
      tr.addEventListener("click", () => showIngredientDetail(parseInt(tr.dataset.id, 10)));
    });

    if (selectedId) showIngredientDetail(selectedId);
  }

  async function showIngredientDetail(id) {
    const container = document.getElementById("ingredient-detail");
    container.innerHTML = `<p class="subtle">Loading history…</p>`;
    let data;
    try {
      data = await api(`/api/ingredients/${id}/history`);
    } catch (e) {
      container.innerHTML = `<div class="empty-state"><p>${escapeHtml(e.message)}</p></div>`;
      return;
    }
    const ing = data.ingredient;
    container.innerHTML = `
      <div class="card">
        <div class="section-header">
          <h3>${escapeHtml(ing.name)} — price history</h3>
          <span class="subtle">${data.history.length} purchases &middot; drift ${data.drift_pct !== null ? pct(data.drift_pct) : "—"}</span>
        </div>
        <canvas class="spark" id="spark-canvas"></canvas>
        <div class="table-scroll" style="margin-top:12px;">
          <table>
            <thead><tr><th>Date</th><th>Qty</th><th>Unit</th><th>Total</th><th>Unit price</th><th>Source</th></tr></thead>
            <tbody>${data.history.slice().reverse().map((h) => `
              <tr><td>${h.date}</td><td>${h.qty}</td><td>${h.unit}</td><td>${money(h.total_price)}</td><td>${money(h.unit_price)}</td><td>${h.source}</td></tr>
            `).join("")}</tbody>
          </table>
        </div>
      </div>`;
    drawSparkline(document.getElementById("spark-canvas"), data.history);
  }

  function drawSparkline(canvas, history) {
    if (!canvas || history.length === 0) return;
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    const w = Math.max(rect.width, 300);
    const h = 140;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    const ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, h);

    const prices = history.map((p) => p.unit_price);
    const min = Math.min(...prices);
    const max = Math.max(...prices);
    const pad = 16;
    const range = max - min || 1;

    ctx.strokeStyle = "#0F5E63";
    ctx.lineWidth = 2;
    ctx.beginPath();
    history.forEach((p, idx) => {
      const x = pad + (idx / Math.max(history.length - 1, 1)) * (w - pad * 2);
      const y = h - pad - ((p.unit_price - min) / range) * (h - pad * 2);
      if (idx === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.stroke();

    ctx.fillStyle = "#E8A33D";
    history.forEach((p, idx) => {
      const x = pad + (idx / Math.max(history.length - 1, 1)) * (w - pad * 2);
      const y = h - pad - ((p.unit_price - min) / range) * (h - pad * 2);
      ctx.beginPath();
      ctx.arc(x, y, idx === history.length - 1 ? 4 : 2.5, 0, Math.PI * 2);
      ctx.fill();
    });

    ctx.fillStyle = "#7a6f61";
    ctx.font = "11px Inter, sans-serif";
    ctx.fillText(money(min), 4, h - 4);
    ctx.textAlign = "right";
    ctx.fillText(money(max), w - 4, 12);
    ctx.textAlign = "left";
  }

  // ---------------------------------------------------------------------
  // RECIPES
  // ---------------------------------------------------------------------
  let recipeItemRows = [];

  async function renderRecipes(editRecipe) {
    app.innerHTML = `<p class="subtle">Loading recipes…</p>`;
    let recipes, ingredients;
    try {
      [recipes, ingredients] = await Promise.all([api("/api/recipes"), api("/api/ingredients")]);
    } catch (e) {
      app.innerHTML = `<div class="empty-state"><h3>Couldn't load recipes</h3><p>${escapeHtml(e.message)}</p></div>`;
      return;
    }
    state.ingredients = ingredients;

    const listHtml = recipes.length ? `
      <div class="table-scroll"><table>
        <thead><tr><th>Recipe</th><th>Plate cost</th><th>Menu price</th><th>FC%</th><th>Status</th><th>Suggested</th><th></th></tr></thead>
        <tbody>${recipes.map((r) => `
          <tr>
            <td>${escapeHtml(r.name)}</td>
            <td>${money(r.plate_cost)}</td>
            <td>${money(r.menu_price)}</td>
            <td>${r.fc_pct.toFixed(1)}%</td>
            <td><span class="chip chip-${r.status}">${r.status}</span></td>
            <td>${money(r.suggested_price)}</td>
            <td>
              <button class="btn btn-secondary btn-sm" data-edit="${r.recipe_id}">Edit</button>
              <button class="btn btn-danger btn-sm" data-delete="${r.recipe_id}">Delete</button>
            </td>
          </tr>`).join("")}</tbody>
      </table></div>` : `<div class="empty-state"><h3>No recipes yet</h3><p>Build your first one below.</p></div>`;

    const editing = editRecipe || null;
    recipeItemRows = editing ? editing.items.map((it) => ({ ingredient_id: it.ingredient_id, qty_base_units: it.qty_base_units })) : [{ ingredient_id: ingredients[0] ? ingredients[0].id : "", qty_base_units: 1 }];

    app.innerHTML = `
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
              <input type="number" id="r-menu-price" step="0.01" min="0.01" value="${editing ? editing.menu_price : ""}" required>
            </div>
            <div class="field">
              <label>Target food cost %</label>
              <input type="number" id="r-target" step="0.1" min="1" value="${editing ? editing.target_fc_pct : 30}" required>
            </div>
          </div>

          <div id="recipe-items"></div>
          <button type="button" class="btn btn-secondary btn-sm" id="add-item">+ Add ingredient</button>

          <div class="recipe-summary" id="recipe-preview"></div>

          <button class="btn" type="submit">${editing ? "Save changes" : "Create recipe"}</button>
          ${editing ? `<button type="button" class="btn btn-secondary" id="cancel-edit">Cancel</button>` : ""}
        </form>
      </div>
    `;

    document.querySelectorAll("[data-edit]").forEach((b) => {
      b.addEventListener("click", async () => {
        const r = await api(`/api/recipes/${b.dataset.edit}`);
        renderRecipes(r);
      });
    });
    document.querySelectorAll("[data-delete]").forEach((b) => {
      b.addEventListener("click", async () => {
        if (!confirm("Delete this recipe?")) return;
        await api(`/api/recipes/${b.dataset.delete}`, { method: "DELETE" });
        toast("Recipe deleted.");
        renderRecipes();
      });
    });
    if (editing) {
      document.getElementById("cancel-edit").addEventListener("click", () => renderRecipes());
    }

    document.getElementById("add-item").addEventListener("click", () => {
      recipeItemRows.push({ ingredient_id: ingredients[0] ? ingredients[0].id : "", qty_base_units: 1 });
      drawRecipeItems();
    });

    function drawRecipeItems() {
      const el = document.getElementById("recipe-items");
      el.innerHTML = recipeItemRows.map((row, idx) => `
        <div class="recipe-item-row" data-idx="${idx}">
          <select class="ri-ingredient">
            ${ingredients.map((i) => `<option value="${i.id}" ${i.id === row.ingredient_id ? "selected" : ""}>${escapeHtml(i.name)} (${i.base_unit})</option>`).join("")}
          </select>
          <input type="number" class="ri-qty" step="0.001" min="0" value="${row.qty_base_units}">
          <button type="button" class="btn btn-danger btn-sm ri-remove">✕</button>
        </div>`).join("");

      el.querySelectorAll(".recipe-item-row").forEach((rowEl) => {
        const idx = parseInt(rowEl.dataset.idx, 10);
        rowEl.querySelector(".ri-ingredient").addEventListener("change", (e) => {
          recipeItemRows[idx].ingredient_id = parseInt(e.target.value, 10);
          updatePreview();
        });
        rowEl.querySelector(".ri-qty").addEventListener("input", (e) => {
          recipeItemRows[idx].qty_base_units = parseFloat(e.target.value) || 0;
          updatePreview();
        });
        rowEl.querySelector(".ri-remove").addEventListener("click", () => {
          recipeItemRows.splice(idx, 1);
          drawRecipeItems();
          updatePreview();
        });
      });
      updatePreview();
    }

    function updatePreview() {
      const byId = {};
      ingredients.forEach((i) => (byId[i.id] = i));
      let plateCost = 0;
      recipeItemRows.forEach((row) => {
        const ing = byId[row.ingredient_id];
        if (ing && ing.latest_price) plateCost += ing.latest_price * row.qty_base_units;
      });
      const menuPrice = parseFloat(document.getElementById("r-menu-price").value) || 0;
      const target = parseFloat(document.getElementById("r-target").value) || 30;
      const fcPct = menuPrice ? (plateCost / menuPrice) * 100 : 0;
      const suggested = target ? Math.ceil((plateCost / (target / 100)) * 2) / 2 : plateCost;
      let status = "ok";
      if (fcPct > target + 2) status = "danger"; else if (fcPct > target) status = "watch";
      document.getElementById("recipe-preview").innerHTML = `
        <div class="stat"><div class="num">${money(plateCost)}</div><div class="lbl">Plate cost</div></div>
        <div class="stat"><div class="num">${fcPct.toFixed(1)}%</div><div class="lbl">Food cost %</div></div>
        <div class="stat"><div class="num"><span class="chip chip-${status}">${status}</span></div><div class="lbl">Status</div></div>
        <div class="stat"><div class="num">${money(suggested)}</div><div class="lbl">Suggested price</div></div>
      `;
    }

    drawRecipeItems();
    document.getElementById("r-menu-price").addEventListener("input", updatePreview);
    document.getElementById("r-target").addEventListener("input", updatePreview);

    document.getElementById("recipe-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const payload = {
        name: document.getElementById("r-name").value.trim(),
        menu_price: parseFloat(document.getElementById("r-menu-price").value),
        target_fc_pct: parseFloat(document.getElementById("r-target").value),
        items: recipeItemRows.filter((r) => r.ingredient_id && r.qty_base_units > 0).map((r) => ({
          ingredient_id: parseInt(r.ingredient_id, 10),
          qty_base_units: r.qty_base_units,
        })),
      };
      if (payload.items.length === 0) {
        toast("Add at least one ingredient.", true);
        return;
      }
      try {
        if (editing) {
          await api(`/api/recipes/${editing.recipe_id}`, { method: "PUT", body: payload });
          toast("Recipe updated.");
        } else {
          await api("/api/recipes", { method: "POST", body: payload });
          toast("Recipe created.");
        }
        renderRecipes();
      } catch (err) {
        toast("Couldn't save recipe: " + err.message, true);
      }
    });
  }

  // ---------------------------------------------------------------------
  // IMPORT
  // ---------------------------------------------------------------------
  async function renderImport() {
    let invoices;
    try {
      invoices = await api("/api/invoices");
    } catch (e) {
      invoices = [];
    }
    state.invoices = invoices;

    app.innerHTML = `
      <div class="section-header"><h2>Import purchases</h2></div>
      <div class="card">
        <p class="subtle">Paste or upload a Sysco-ish CSV with columns: <code>item,vendor,date,qty,unit,total</code></p>
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
      </div>

      <div class="section-header"><h2>Invoice photo upload</h2></div>
      <div class="two-col">
        <div class="card">
          <p class="subtle">Snap a photo of a paper invoice, upload it here, then enter the numbers manually alongside it. (Photo-assisted entry — no OCR extraction in v1.)</p>
          <form id="invoice-form">
            <div class="field">
              <label>Invoice photo</label>
              <input type="file" id="invoice-file" accept="image/*" required>
            </div>
            <button class="btn btn-amber" type="submit" style="margin-top:10px;">Upload</button>
          </form>
          <div id="invoice-list" class="pill-list"></div>
        </div>
        <div class="card">
          <h3>Manual entry</h3>
          <p class="subtle">Use the quick-entry purchase form on the Ingredients tab — attach the uploaded invoice from the "Attach invoice" dropdown there.</p>
          <div id="invoice-preview"></div>
        </div>
      </div>
    `;

    function renderInvoiceList() {
      const el = document.getElementById("invoice-list");
      if (state.invoices.length === 0) {
        el.innerHTML = `<span class="subtle">No invoices uploaded yet.</span>`;
        return;
      }
      el.innerHTML = state.invoices.map((iv) => `
        <span class="pill" data-iv="${iv.id}">${escapeHtml(iv.filename)} — ${iv.status}</span>
      `).join("");
      el.querySelectorAll(".pill").forEach((p) => {
        p.addEventListener("click", () => {
          const iv = state.invoices.find((x) => x.id === parseInt(p.dataset.iv, 10));
          document.getElementById("invoice-preview").innerHTML = iv ? `<img class="invoice-thumb" src="${iv.url}" alt="invoice">` : "";
        });
      });
    }
    renderInvoiceList();

    document.getElementById("csv-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const file = document.getElementById("csv-file").files[0];
      const text = document.getElementById("csv-text").value.trim();
      if (!file && !text) {
        toast("Paste some CSV or choose a file first.", true);
        return;
      }
      try {
        let result;
        if (file) {
          const fd = new FormData();
          fd.append("file", file);
          result = await api("/api/purchases/import", { method: "POST", body: fd });
        } else {
          const fd = new FormData();
          fd.append("csv_text", text);
          result = await api("/api/purchases/import", { method: "POST", body: fd });
        }
        const errHtml = result.errors.length
          ? `<p style="color:var(--paprika)">${result.errors.length} row(s) had errors: ${result.errors.map((er) => `row ${er.row}: ${escapeHtml(er.error)}`).join("; ")}</p>`
          : "";
        document.getElementById("import-result").innerHTML = `
          <div class="match-hint" style="margin-top:10px;">
            Processed ${result.rows_processed} row(s): ${result.created} new ingredient(s), ${result.matched} matched to existing.
          </div>${errHtml}`;
        toast(`Imported ${result.rows_processed} row(s).`);
      } catch (err) {
        toast("Import failed: " + err.message, true);
      }
    });

    document.getElementById("invoice-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const file = document.getElementById("invoice-file").files[0];
      if (!file) return;
      const fd = new FormData();
      fd.append("file", file);
      try {
        const r = await api("/api/invoices", { method: "POST", body: fd });
        state.invoices.unshift(r);
        renderInvoiceList();
        toast("Invoice uploaded. Enter its numbers on the Ingredients tab.");
        document.getElementById("invoice-file").value = "";
      } catch (err) {
        toast("Upload failed: " + err.message, true);
      }
    });
  }

  // ---------------------------------------------------------------------
  // SETTINGS
  // ---------------------------------------------------------------------
  async function renderSettings() {
    let s;
    try {
      s = await api("/api/settings");
    } catch (e) {
      app.innerHTML = `<div class="empty-state"><p>${escapeHtml(e.message)}</p></div>`;
      return;
    }
    app.innerHTML = `
      <div class="section-header"><h2>Settings</h2></div>
      <div class="card" style="max-width:480px;">
        <form id="settings-form">
          <div class="field" style="margin-bottom:12px;">
            <label>Restaurant name</label>
            <input type="text" id="s-name" value="${escapeHtml(s.restaurant_name)}">
          </div>
          <div class="field" style="margin-bottom:12px;">
            <label>Default target food cost % (new recipes)</label>
            <input type="number" id="s-target" step="0.1" min="1" value="${s.target_fc_pct}">
          </div>
          <div class="field" style="margin-bottom:12px;">
            <label>Drift alert threshold %</label>
            <input type="number" id="s-threshold" step="0.1" min="0.1" value="${s.drift_threshold_pct}">
          </div>
          <button class="btn" type="submit">Save settings</button>
        </form>
      </div>
    `;
    document.getElementById("settings-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await api("/api/settings", {
          method: "PUT",
          body: {
            restaurant_name: document.getElementById("s-name").value.trim(),
            target_fc_pct: parseFloat(document.getElementById("s-target").value),
            drift_threshold_pct: parseFloat(document.getElementById("s-threshold").value),
          },
        });
        toast("Settings saved.");
        document.getElementById("restaurant-name").textContent = document.getElementById("s-name").value.trim();
      } catch (err) {
        toast("Couldn't save settings: " + err.message, true);
      }
    });
  }

  // ---------------------------------------------------------------------
  // boot
  // ---------------------------------------------------------------------
  render();
})();
