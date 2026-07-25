(function () {
  "use strict";

  /* ---------- Mobile nav ---------- */
  var navToggle = document.getElementById("navToggle");
  var navLinks = document.getElementById("navLinks");
  if (navToggle && navLinks) {
    navToggle.addEventListener("click", function () {
      var isOpen = navLinks.classList.toggle("is-open");
      navToggle.setAttribute("aria-expanded", isOpen ? "true" : "false");
    });
    navLinks.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () {
        navLinks.classList.remove("is-open");
        navToggle.setAttribute("aria-expanded", "false");
      });
    });
  }

  /* ---------- Food cost calculator ---------- */
  var TARGET_PCT = 30;

  var itemNameInput = document.getElementById("itemName");
  var menuPriceInput = document.getElementById("menuPrice");
  var rowsContainer = document.getElementById("ingredientRows");
  var addRowBtn = document.getElementById("addRow");

  var plateCostEl = document.getElementById("resultPlateCost");
  var foodCostPctEl = document.getElementById("resultFoodCostPct");
  var foodCostTile = document.getElementById("foodCostTile");
  var suggestedPriceEl = document.getElementById("resultSuggestedPrice");
  var verdictEl = document.getElementById("verdictText");

  var rowIdCounter = 0;

  var DEFAULT_ROWS = [
    { name: "Chicken wings", qty: 1.5, unitCost: 3.00 },
    { name: "Buffalo sauce", qty: 0.3, unitCost: 2.00 },
    { name: "Celery & blue cheese", qty: 1, unitCost: 0.60 }
  ];

  function fmtMoney(n) {
    if (!isFinite(n)) n = 0;
    var sign = n < 0 ? "-" : "";
    return sign + "$" + Math.abs(n).toFixed(2);
  }

  function fmtPercent(n) {
    if (!isFinite(n)) n = 0;
    return n.toFixed(1) + "%";
  }

  // Round to the nearest cent first (kills floating-point noise), then
  // round UP to the next $0.50 increment. Values already on a .50/.00
  // boundary are left unchanged.
  function roundUpToHalfDollar(value) {
    if (!isFinite(value) || value <= 0) return 0;
    var cents = Math.round(value * 100);
    var stepCents = 50;
    var roundedCents = Math.ceil((cents - 1e-6) / stepCents) * stepCents;
    return roundedCents / 100;
  }

  function createRow(data) {
    rowIdCounter += 1;
    var rowId = "row-" + rowIdCounter;

    var row = document.createElement("div");
    row.className = "ingredient-row";
    row.dataset.rowId = rowId;

    row.innerHTML =
      '<div class="field-name">' +
        '<input type="text" class="ing-name" placeholder="Ingredient name" value="' + escapeAttr(data.name || "") + '" autocomplete="off">' +
      '</div>' +
      '<div class="field-qty">' +
        '<input type="number" class="ing-qty" min="0" step="any" placeholder="0" value="' + (data.qty != null ? data.qty : "") + '" inputmode="decimal">' +
      '</div>' +
      '<div class="field-unit">' +
        '<input type="number" class="ing-unit" min="0" step="0.01" placeholder="0.00" value="' + (data.unitCost != null ? data.unitCost : "") + '" inputmode="decimal">' +
      '</div>' +
      '<span class="row-cost">$0.00</span>' +
      '<button type="button" class="row-remove" title="Remove ingredient" aria-label="Remove ingredient">&times;</button>';

    rowsContainer.appendChild(row);
    return row;
  }

  function escapeAttr(str) {
    return String(str).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  }

  function addRow(data) {
    createRow(data || {});
    updateRemoveButtons();
    calculate();
  }

  function removeRow(row) {
    if (rowsContainer.children.length <= 1) return;
    row.remove();
    updateRemoveButtons();
    calculate();
  }

  function updateRemoveButtons() {
    var rows = rowsContainer.querySelectorAll(".ingredient-row");
    rows.forEach(function (row) {
      var btn = row.querySelector(".row-remove");
      btn.disabled = rows.length <= 1;
    });
  }

  function getRowData(row) {
    var qty = parseFloat(row.querySelector(".ing-qty").value);
    var unitCost = parseFloat(row.querySelector(".ing-unit").value);
    if (!isFinite(qty) || qty < 0) qty = 0;
    if (!isFinite(unitCost) || unitCost < 0) unitCost = 0;
    return { qty: qty, unitCost: unitCost, cost: qty * unitCost };
  }

  function calculate() {
    var rows = rowsContainer.querySelectorAll(".ingredient-row");
    var plateCost = 0;

    rows.forEach(function (row) {
      var data = getRowData(row);
      plateCost += data.cost;
      row.querySelector(".row-cost").textContent = fmtMoney(data.cost);
    });

    var menuPrice = parseFloat(menuPriceInput.value);
    if (!isFinite(menuPrice) || menuPrice < 0) menuPrice = 0;

    var foodCostPct = menuPrice > 0 ? (plateCost / menuPrice) * 100 : 0;
    var suggestedPrice = roundUpToHalfDollar(plateCost / (TARGET_PCT / 100));

    plateCostEl.textContent = fmtMoney(plateCost);
    foodCostPctEl.textContent = menuPrice > 0 ? fmtPercent(foodCostPct) : "—";
    suggestedPriceEl.textContent = plateCost > 0 ? fmtMoney(suggestedPrice) : fmtMoney(0);

    updateVerdict(plateCost, menuPrice, foodCostPct);
  }

  function updateVerdict(plateCost, menuPrice, foodCostPct) {
    foodCostTile.classList.remove("state-over", "state-under", "state-target");
    verdictEl.classList.remove("is-over", "is-under", "is-target");

    if (plateCost <= 0 || menuPrice <= 0) {
      verdictEl.textContent = "Add a menu price and at least one ingredient to see your numbers.";
      return;
    }

    var itemName = (itemNameInput.value || "").trim();
    var prefix = itemName ? itemName + " — " : "";
    var diffPoints = foodCostPct - TARGET_PCT;
    var lostPerPlate = plateCost - (TARGET_PCT / 100) * menuPrice;
    var roundedDiff = parseFloat(diffPoints.toFixed(1));

    var sentence;
    if (roundedDiff === 0) {
      foodCostTile.classList.add("state-target");
      verdictEl.classList.add("is-target");
      sentence = prefix + "At " + fmtMoney(menuPrice) + ", this dish lands right at a 30% food-cost target.";
    } else if (roundedDiff > 0) {
      foodCostTile.classList.add("state-over");
      verdictEl.classList.add("is-over");
      sentence = prefix + "At " + fmtMoney(menuPrice) + ", this dish is " + roundedDiff.toFixed(1) +
        " points over a 30% target — that's " + fmtMoney(Math.abs(lostPerPlate)) + " lost per plate.";
    } else {
      foodCostTile.classList.add("state-under");
      verdictEl.classList.add("is-under");
      sentence = prefix + "At " + fmtMoney(menuPrice) + ", this dish is " + Math.abs(roundedDiff).toFixed(1) +
        " points under a 30% target — that's " + fmtMoney(Math.abs(lostPerPlate)) + " of extra margin per plate.";
    }

    verdictEl.textContent = sentence;
  }

  // Event delegation for row inputs + remove buttons
  rowsContainer.addEventListener("input", function (e) {
    if (e.target.matches(".ing-qty, .ing-unit, .ing-name")) {
      calculate();
    }
  });

  rowsContainer.addEventListener("click", function (e) {
    var btn = e.target.closest(".row-remove");
    if (btn) {
      removeRow(btn.closest(".ingredient-row"));
    }
  });

  addRowBtn.addEventListener("click", function () {
    addRow({ name: "", qty: "", unitCost: "" });
  });

  menuPriceInput.addEventListener("input", calculate);
  itemNameInput.addEventListener("input", calculate);

  // Seed default rows
  DEFAULT_ROWS.forEach(addRow);
  updateRemoveButtons();
  calculate();

  // Expose for verification/testing in a headless context
  window.__costsauceCalc = {
    roundUpToHalfDollar: roundUpToHalfDollar,
    calculate: calculate
  };
})();
