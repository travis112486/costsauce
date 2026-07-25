# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastapi>=0.110",
#   "uvicorn[standard]>=0.29",
#   "python-multipart>=0.0.9",
# ]
# ///
"""CostSauce — price-drift radar for independent restaurants.

Run with: uv run app.py
Serves on http://localhost:8321
"""
import csv
import io
import math
import os
import random
import re
import sqlite3
from datetime import date, datetime, timedelta
from typing import List, Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")
DB_PATH = os.path.join(os.getcwd(), "costsauce.db")
UPLOAD_DIR = os.path.join(os.getcwd(), "uploads")

WEIGHT_TO_LB = {"lb": 1.0, "oz": 1 / 16, "kg": 2.2046226218, "g": 2.2046226218 / 1000}


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db():
    conn = get_conn()
    try:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS ingredients (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                base_unit TEXT NOT NULL,
                vendor TEXT,
                category TEXT
            );
            CREATE TABLE IF NOT EXISTS purchases (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ingredient_id INTEGER NOT NULL REFERENCES ingredients(id),
                date TEXT NOT NULL,
                qty REAL NOT NULL,
                unit TEXT NOT NULL,
                total_price REAL NOT NULL,
                unit_price REAL NOT NULL,
                source TEXT NOT NULL DEFAULT 'manual'
            );
            CREATE TABLE IF NOT EXISTS recipes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                menu_price REAL NOT NULL,
                target_fc_pct REAL NOT NULL DEFAULT 30
            );
            CREATE TABLE IF NOT EXISTS recipe_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recipe_id INTEGER NOT NULL REFERENCES recipes(id),
                ingredient_id INTEGER NOT NULL REFERENCES ingredients(id),
                qty_base_units REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS invoices (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                uploaded_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'manual'
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            """
        )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Ingredient fuzzy matching
# ---------------------------------------------------------------------------
def normalize_name(name: str) -> str:
    s = name.lower().strip()
    s = re.sub(r"[^a-z0-9\s]", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    if s.endswith("s") and not s.endswith("ss") and len(s) > 3:
        s = s[:-1]
    return s


def find_ingredient_match(conn, name: str):
    norm = normalize_name(name)
    if not norm:
        return None
    rows = conn.execute("SELECT id, name FROM ingredients").fetchall()
    for r in rows:
        if normalize_name(r["name"]) == norm:
            return r["id"], r["name"], "exact"
    for r in rows:
        rn = normalize_name(r["name"])
        if norm in rn or rn in norm:
            return r["id"], r["name"], "fuzzy"
    return None


# ---------------------------------------------------------------------------
# Unit normalization
# ---------------------------------------------------------------------------
def normalize_purchase(base_unit: str, qty: float, unit: str, total_price: float,
                        qty_in_case: Optional[float] = None):
    if qty is None or qty <= 0 or total_price is None or total_price <= 0:
        raise HTTPException(400, "qty and total_price must be positive")
    unit = (unit or "").strip().lower()
    if unit == "case":
        if not qty_in_case or qty_in_case <= 0:
            raise HTTPException(400, "qty_in_case is required when unit is 'case'")
        base_qty = qty * qty_in_case
    elif base_unit == "each":
        if unit != "each":
            raise HTTPException(400, "this ingredient is tracked 'each' — use unit 'each' or 'case'")
        base_qty = qty
    else:
        if unit not in WEIGHT_TO_LB:
            raise HTTPException(400, f"unsupported unit '{unit}' for a weight-tracked ingredient")
        base_qty = qty * WEIGHT_TO_LB[unit] / WEIGHT_TO_LB.get(base_unit, 1.0)
    unit_price = total_price / base_qty
    return base_qty, base_unit, unit_price


def ceil_to_half(x: float) -> float:
    return math.ceil(x * 2) / 2


# ---------------------------------------------------------------------------
# Drift + costing engine
# ---------------------------------------------------------------------------
def get_ingredient_drift(conn, ingredient_id: int):
    rows = conn.execute(
        "SELECT date, unit_price FROM purchases WHERE ingredient_id=? ORDER BY date DESC, id DESC",
        (ingredient_id,),
    ).fetchall()
    if not rows:
        return None
    latest = rows[0]
    latest_date = date.fromisoformat(latest["date"])
    cutoff = latest_date - timedelta(days=90)
    baseline = [r["unit_price"] for r in rows[1:] if date.fromisoformat(r["date"]) >= cutoff]
    if not baseline:
        return {
            "latest_price": latest["unit_price"],
            "trailing_avg": None,
            "drift_pct": 0.0,
            "latest_date": latest["date"],
        }
    trailing_avg = sum(baseline) / len(baseline)
    drift_pct = (latest["unit_price"] - trailing_avg) / trailing_avg * 100 if trailing_avg else 0.0
    return {
        "latest_price": latest["unit_price"],
        "trailing_avg": trailing_avg,
        "drift_pct": drift_pct,
        "latest_date": latest["date"],
    }


def cost_recipe(conn, recipe) -> dict:
    items = conn.execute(
        """SELECT ri.qty_base_units, i.id AS ingredient_id, i.name, i.base_unit
           FROM recipe_items ri JOIN ingredients i ON i.id = ri.ingredient_id
           WHERE ri.recipe_id = ?""",
        (recipe["id"],),
    ).fetchall()
    plate_cost = 0.0
    item_details = []
    for it in items:
        drift = get_ingredient_drift(conn, it["ingredient_id"])
        price = drift["latest_price"] if drift else 0.0
        cost = it["qty_base_units"] * price
        plate_cost += cost
        item_details.append(
            {
                "ingredient_id": it["ingredient_id"],
                "name": it["name"],
                "base_unit": it["base_unit"],
                "qty_base_units": it["qty_base_units"],
                "unit_price": round(price, 2),
                "cost": round(cost, 2),
            }
        )
    menu_price = recipe["menu_price"]
    fc_pct = (plate_cost / menu_price * 100) if menu_price else 0.0
    target = recipe["target_fc_pct"]
    if fc_pct <= target:
        status = "ok"
    elif fc_pct <= target + 2:
        status = "watch"
    else:
        status = "danger"
    suggested = ceil_to_half(plate_cost / (target / 100)) if target else round(plate_cost, 2)
    return {
        "recipe_id": recipe["id"],
        "name": recipe["name"],
        "menu_price": round(menu_price, 2),
        "target_fc_pct": target,
        "plate_cost": round(plate_cost, 2),
        "fc_pct": round(fc_pct, 1),
        "status": status,
        "suggested_price": suggested,
        "items": item_details,
    }


def get_settings(conn) -> dict:
    rows = conn.execute("SELECT key, value FROM settings").fetchall()
    d = {r["key"]: r["value"] for r in rows}
    return {
        "target_fc_pct": float(d.get("target_fc_pct", 30)),
        "drift_threshold_pct": float(d.get("drift_threshold_pct", 5)),
        "restaurant_name": d.get("restaurant_name", "The Copper Ladle"),
    }


def set_setting(conn, key: str, value):
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )


# ---------------------------------------------------------------------------
# Seed data — "The Copper Ladle"
# ---------------------------------------------------------------------------
# name, base_unit, vendor, category, base_price, drift_pct, (order qty min, max)
INGREDIENTS = [
    ("Chicken Wings", "lb", "Reinhart Foodservice", "Protein", 2.60, 3.0, (20, 40)),
    ("Chicken Breast", "lb", "Reinhart Foodservice", "Protein", 3.20, 14.0, (20, 40)),
    ("Ground Beef 80/20", "lb", "Reinhart Foodservice", "Protein", 4.50, 9.0, (20, 40)),
    ("Ribeye Steak", "lb", "Reinhart Foodservice", "Protein", 14.00, 1.5, (10, 20)),
    ("Cod Fillet", "lb", "Reinhart Foodservice", "Protein", 7.50, 7.0, (10, 25)),
    ("Corn Tortillas", "each", "US Foods", "Bakery", 0.08, 0.5, (200, 400)),
    ("Brioche Bun", "each", "US Foods", "Bakery", 0.65, 1.0, (48, 96)),
    ("Romaine Lettuce", "each", "Fresh Point Produce", "Produce", 1.80, 2.5, (20, 40)),
    ("Cheddar Cheese", "lb", "Sysco", "Dairy", 4.20, 3.5, (10, 20)),
    ("Parmesan Cheese", "lb", "Sysco", "Dairy", 9.50, 1.0, (5, 10)),
    ("Tomato", "lb", "Fresh Point Produce", "Produce", 2.20, -2.5, (15, 30)),
    ("Avocado", "each", "Fresh Point Produce", "Produce", 0.90, 4.0, (40, 80)),
    ("Lime", "each", "Fresh Point Produce", "Produce", 0.28, 31.0, (60, 120)),
    ("Russet Potato", "lb", "Fresh Point Produce", "Produce", 0.70, 1.0, (30, 60)),
    ("Butter", "lb", "Sysco", "Dairy", 3.80, 2.0, (10, 20)),
    ("All-Purpose Flour", "lb", "Sysco", "Dry Goods", 0.55, -3.0, (20, 40)),
    ("Sugar", "lb", "Sysco", "Dry Goods", 0.65, 0.5, (20, 40)),
    ("Cocoa Powder", "lb", "Sysco", "Dry Goods", 6.50, 1.5, (5, 10)),
    ("Eggs", "each", "Sysco", "Dairy", 0.32, 3.0, (60, 120)),
    ("Heavy Cream", "each", "Sysco", "Dairy", 4.10, 2.0, (10, 20)),
    ("Truffle Oil", "each", "Regalis Foods", "Specialty", 18.00, -0.5, (2, 5)),
    ("Vegetable Oil", "each", "US Foods", "Dry Goods", 9.50, 1.0, (5, 10)),
    ("Buffalo Sauce", "each", "US Foods", "Condiment", 6.00, 2.0, (5, 12)),
    ("Caesar Dressing", "each", "US Foods", "Condiment", 7.50, 1.0, (5, 12)),
]

RECIPES = [
    ("Buffalo Wings", 32, [("Chicken Wings", 1.0), ("Buffalo Sauce", 0.15)]),
    ("Classic Burger", 30, [("Ground Beef 80/20", 0.33), ("Brioche Bun", 1), ("Cheddar Cheese", 0.0625),
                            ("Tomato", 0.1), ("Romaine Lettuce", 0.05)]),
    ("Fish Tacos", 30, [("Cod Fillet", 0.5), ("Corn Tortillas", 3), ("Avocado", 0.5),
                        ("Lime", 0.5), ("Tomato", 0.15)]),
    ("Caesar Salad", 28, [("Romaine Lettuce", 0.5), ("Parmesan Cheese", 0.08), ("Caesar Dressing", 0.2)]),
    ("Ribeye", 38, [("Ribeye Steak", 0.75), ("Butter", 0.03), ("Russet Potato", 0.5)]),
    ("Margarita-Lime Chicken", 30, [("Chicken Breast", 0.5), ("Lime", 1.0), ("Vegetable Oil", 0.03)]),
    ("Truffle Fries", 26, [("Russet Potato", 0.6), ("Truffle Oil", 0.04), ("Parmesan Cheese", 0.05),
                           ("Vegetable Oil", 0.05)]),
    ("Chocolate Cake", 20, [("Cocoa Powder", 0.15), ("All-Purpose Flour", 0.2), ("Sugar", 0.25),
                            ("Butter", 0.15), ("Eggs", 3), ("Heavy Cream", 0.3)]),
]

# purchases spread over ~10 weeks: 9 historical weekly points + 1 latest (the "today" price)
HISTORICAL_OFFSETS_DAYS = [72, 65, 58, 51, 44, 37, 30, 23, 16]
LATEST_OFFSET_DAYS = 2


def seed_if_empty():
    conn = get_conn()
    try:
        count = conn.execute("SELECT COUNT(*) c FROM ingredients").fetchone()["c"]
        if count > 0:
            return
        today = date.today()
        name_to_id = {}
        for name, base_unit, vendor, category, base_price, drift_pct, qty_range in INGREDIENTS:
            cur = conn.execute(
                "INSERT INTO ingredients (name, base_unit, vendor, category) VALUES (?, ?, ?, ?)",
                (name, base_unit, vendor, category),
            )
            iid = cur.lastrowid
            name_to_id[name] = iid
            rng = random.Random(f"costsauce-seed-{name}")
            historical_prices = []
            for off in HISTORICAL_OFFSETS_DAYS:
                noise = rng.uniform(-0.02, 0.02)
                price = base_price * (1 + noise)
                historical_prices.append(price)
                qty = rng.uniform(*qty_range)
                total = price * qty
                pdate = (today - timedelta(days=off)).isoformat()
                conn.execute(
                    """INSERT INTO purchases (ingredient_id, date, qty, unit, total_price, unit_price, source)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (iid, pdate, round(qty, 2), base_unit, round(total, 2), round(price, 4), "seed"),
                )
            historical_avg = sum(historical_prices) / len(historical_prices)
            latest_price = historical_avg * (1 + drift_pct / 100)
            latest_qty = rng.uniform(*qty_range)
            latest_total = latest_price * latest_qty
            latest_date = (today - timedelta(days=LATEST_OFFSET_DAYS)).isoformat()
            conn.execute(
                """INSERT INTO purchases (ingredient_id, date, qty, unit, total_price, unit_price, source)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (iid, latest_date, round(latest_qty, 2), base_unit, round(latest_total, 2),
                 round(latest_price, 4), "seed"),
            )

        set_setting(conn, "target_fc_pct", 30)
        set_setting(conn, "drift_threshold_pct", 5)
        set_setting(conn, "restaurant_name", "The Copper Ladle")

        base_prices = {n: bp for (n, _, _, _, bp, _, _) in INGREDIENTS}
        for rname, target, items in RECIPES:
            plate_cost_pre = sum(qty * base_prices[iname] for iname, qty in items)
            menu_price = ceil_to_half(plate_cost_pre / (target / 100))
            cur = conn.execute(
                "INSERT INTO recipes (name, menu_price, target_fc_pct) VALUES (?, ?, ?)",
                (rname, menu_price, target),
            )
            rid = cur.lastrowid
            for iname, qty in items:
                conn.execute(
                    "INSERT INTO recipe_items (recipe_id, ingredient_id, qty_base_units) VALUES (?, ?, ?)",
                    (rid, name_to_id[iname], qty),
                )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
os.makedirs(UPLOAD_DIR, exist_ok=True)
init_db()
seed_if_empty()

app = FastAPI(title="CostSauce")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
app.mount("/uploads", StaticFiles(directory=UPLOAD_DIR), name="uploads")


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------
class IngredientIn(BaseModel):
    name: str
    base_unit: str = "each"
    vendor: Optional[str] = None
    category: Optional[str] = None


class IngredientUpdate(BaseModel):
    name: Optional[str] = None
    base_unit: Optional[str] = None
    vendor: Optional[str] = None
    category: Optional[str] = None


class PurchaseIn(BaseModel):
    ingredient_id: Optional[int] = None
    ingredient_name: Optional[str] = None
    base_unit: Optional[str] = "each"
    vendor: Optional[str] = None
    category: Optional[str] = None
    date: str
    qty: float
    unit: str
    qty_in_case: Optional[float] = None
    total_price: float
    source: str = "manual"
    invoice_id: Optional[int] = None


class RecipeItemIn(BaseModel):
    ingredient_id: int
    qty_base_units: float


class RecipeIn(BaseModel):
    name: str
    menu_price: float
    target_fc_pct: float = 30
    items: List[RecipeItemIn] = []


class SettingsIn(BaseModel):
    target_fc_pct: Optional[float] = None
    drift_threshold_pct: Optional[float] = None
    restaurant_name: Optional[str] = None


# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
@app.get("/api/dashboard")
def dashboard():
    conn = get_conn()
    try:
        settings = get_settings(conn)
        threshold = settings["drift_threshold_pct"]
        ingredients = conn.execute("SELECT * FROM ingredients").fetchall()
        movers = []
        for ing in ingredients:
            drift = get_ingredient_drift(conn, ing["id"])
            if drift is None:
                continue
            entry = {
                "ingredient_id": ing["id"],
                "name": ing["name"],
                "category": ing["category"],
                "vendor": ing["vendor"],
                "latest_price": round(drift["latest_price"], 2),
                "trailing_avg": round(drift["trailing_avg"], 2) if drift["trailing_avg"] else None,
                "drift_pct": round(drift["drift_pct"], 1),
                "direction": "up" if drift["drift_pct"] > 0 else "down",
            }
            movers.append(entry)
        movers.sort(key=lambda x: abs(x["drift_pct"]), reverse=True)
        alerts = [m for m in movers if abs(m["drift_pct"]) >= threshold]

        recipes = conn.execute("SELECT * FROM recipes ORDER BY name").fetchall()
        menu_items = [cost_recipe(conn, r) for r in recipes]
        danger = sum(1 for m in menu_items if m["status"] == "danger")
        watch = sum(1 for m in menu_items if m["status"] == "watch")
        ok = sum(1 for m in menu_items if m["status"] == "ok")
        avg_fc = round(sum(m["fc_pct"] for m in menu_items) / len(menu_items), 1) if menu_items else 0.0

        return {
            "restaurant": settings["restaurant_name"],
            "alerts": alerts,
            "top_movers": movers[:5],
            "menu_items": menu_items,
            "summary": {
                "total_alerts": len(alerts),
                "avg_fc_pct": avg_fc,
                "danger_count": danger,
                "watch_count": watch,
                "ok_count": ok,
                "drift_threshold_pct": threshold,
            },
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Ingredients
# ---------------------------------------------------------------------------
@app.get("/api/ingredients")
def list_ingredients():
    conn = get_conn()
    try:
        rows = conn.execute("SELECT * FROM ingredients ORDER BY name").fetchall()
        result = []
        for r in rows:
            drift = get_ingredient_drift(conn, r["id"])
            pcount = conn.execute(
                "SELECT COUNT(*) c FROM purchases WHERE ingredient_id=?", (r["id"],)
            ).fetchone()["c"]
            result.append(
                {
                    "id": r["id"],
                    "name": r["name"],
                    "base_unit": r["base_unit"],
                    "vendor": r["vendor"],
                    "category": r["category"],
                    "latest_price": round(drift["latest_price"], 2) if drift else None,
                    "trailing_avg": round(drift["trailing_avg"], 2) if drift and drift["trailing_avg"] else None,
                    "drift_pct": round(drift["drift_pct"], 1) if drift else None,
                    "purchase_count": pcount,
                }
            )
        return result
    finally:
        conn.close()


@app.get("/api/ingredients/match")
def match_ingredient(name: str):
    conn = get_conn()
    try:
        match = find_ingredient_match(conn, name)
        if not match:
            return {"match": None}
        return {"match": {"id": match[0], "name": match[1], "type": match[2]}}
    finally:
        conn.close()


@app.post("/api/ingredients")
def create_ingredient(body: IngredientIn):
    conn = get_conn()
    try:
        existing = find_ingredient_match(conn, body.name)
        if existing:
            raise HTTPException(
                409,
                detail={
                    "message": f"'{body.name}' looks like an existing ingredient",
                    "match": {"id": existing[0], "name": existing[1], "type": existing[2]},
                },
            )
        cur = conn.execute(
            "INSERT INTO ingredients (name, base_unit, vendor, category) VALUES (?, ?, ?, ?)",
            (body.name.strip(), body.base_unit, body.vendor, body.category),
        )
        conn.commit()
        return {"id": cur.lastrowid, "name": body.name.strip(), "base_unit": body.base_unit,
                "vendor": body.vendor, "category": body.category}
    finally:
        conn.close()


@app.put("/api/ingredients/{iid}")
def update_ingredient(iid: int, body: IngredientUpdate):
    conn = get_conn()
    try:
        row = conn.execute("SELECT * FROM ingredients WHERE id=?", (iid,)).fetchone()
        if not row:
            raise HTTPException(404, "ingredient not found")
        name = body.name if body.name is not None else row["name"]
        base_unit = body.base_unit if body.base_unit is not None else row["base_unit"]
        vendor = body.vendor if body.vendor is not None else row["vendor"]
        category = body.category if body.category is not None else row["category"]
        conn.execute(
            "UPDATE ingredients SET name=?, base_unit=?, vendor=?, category=? WHERE id=?",
            (name, base_unit, vendor, category, iid),
        )
        conn.commit()
        return {"id": iid, "name": name, "base_unit": base_unit, "vendor": vendor, "category": category}
    finally:
        conn.close()


@app.delete("/api/ingredients/{iid}")
def delete_ingredient(iid: int):
    conn = get_conn()
    try:
        used = conn.execute(
            "SELECT COUNT(*) c FROM recipe_items WHERE ingredient_id=?", (iid,)
        ).fetchone()["c"]
        if used > 0:
            raise HTTPException(400, "ingredient is used in one or more recipes — remove it there first")
        conn.execute("DELETE FROM purchases WHERE ingredient_id=?", (iid,))
        cur = conn.execute("DELETE FROM ingredients WHERE id=?", (iid,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, "ingredient not found")
        return {"deleted": True}
    finally:
        conn.close()


@app.get("/api/ingredients/{iid}/history")
def ingredient_history(iid: int):
    conn = get_conn()
    try:
        ing = conn.execute("SELECT * FROM ingredients WHERE id=?", (iid,)).fetchone()
        if not ing:
            raise HTTPException(404, "ingredient not found")
        rows = conn.execute(
            "SELECT date, qty, unit, total_price, unit_price, source FROM purchases "
            "WHERE ingredient_id=? ORDER BY date ASC, id ASC",
            (iid,),
        ).fetchall()
        drift = get_ingredient_drift(conn, iid)
        return {
            "ingredient": {"id": ing["id"], "name": ing["name"], "base_unit": ing["base_unit"],
                           "vendor": ing["vendor"], "category": ing["category"]},
            "history": [dict(r) for r in rows],
            "drift_pct": round(drift["drift_pct"], 1) if drift else None,
            "latest_price": round(drift["latest_price"], 2) if drift else None,
            "trailing_avg": round(drift["trailing_avg"], 2) if drift and drift["trailing_avg"] else None,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Purchases
# ---------------------------------------------------------------------------
@app.post("/api/purchases")
def create_purchase(p: PurchaseIn):
    conn = get_conn()
    try:
        ingredient_id = p.ingredient_id
        matched_type = "explicit"
        if ingredient_id is None:
            if not p.ingredient_name:
                raise HTTPException(400, "ingredient_id or ingredient_name is required")
            match = find_ingredient_match(conn, p.ingredient_name)
            if match:
                ingredient_id, _, matched_type = match
            else:
                cur = conn.execute(
                    "INSERT INTO ingredients (name, base_unit, vendor, category) VALUES (?, ?, ?, ?)",
                    (p.ingredient_name.strip(), p.base_unit or "each", p.vendor, p.category),
                )
                ingredient_id = cur.lastrowid
                matched_type = "created"

        ing = conn.execute("SELECT * FROM ingredients WHERE id=?", (ingredient_id,)).fetchone()
        if not ing:
            raise HTTPException(404, "ingredient not found")

        base_qty, base_unit, unit_price = normalize_purchase(
            ing["base_unit"], p.qty, p.unit, p.total_price, p.qty_in_case
        )
        cur = conn.execute(
            """INSERT INTO purchases (ingredient_id, date, qty, unit, total_price, unit_price, source)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (ingredient_id, p.date, round(base_qty, 4), base_unit, round(p.total_price, 2),
             round(unit_price, 4), p.source),
        )
        purchase_id = cur.lastrowid
        if p.invoice_id:
            conn.execute("UPDATE invoices SET status='entered' WHERE id=?", (p.invoice_id,))
        conn.commit()
        drift = get_ingredient_drift(conn, ingredient_id)
        return {
            "id": purchase_id,
            "ingredient_id": ingredient_id,
            "ingredient_name": ing["name"],
            "matched": matched_type,
            "qty": round(base_qty, 4),
            "unit": base_unit,
            "unit_price": round(unit_price, 4),
            "drift_pct": round(drift["drift_pct"], 1) if drift else None,
        }
    finally:
        conn.close()


@app.post("/api/purchases/import")
async def import_purchases(file: Optional[UploadFile] = File(None), csv_text: Optional[str] = Form(None)):
    if file is not None:
        content = (await file.read()).decode("utf-8", errors="ignore")
    elif csv_text:
        content = csv_text
    else:
        raise HTTPException(400, "provide a file or csv_text")

    reader = csv.DictReader(io.StringIO(content.strip()))
    fieldmap = {(f or "").strip().lower(): f for f in (reader.fieldnames or [])}
    required = ["item", "vendor", "date", "qty", "unit", "total"]
    missing = [c for c in required if c not in fieldmap]
    if missing:
        raise HTTPException(400, f"CSV missing required column(s): {', '.join(missing)}")

    conn = get_conn()
    created, matched, errors = 0, 0, []
    rows_processed = 0
    try:
        for i, row in enumerate(reader, start=2):
            rows_processed += 1
            try:
                item = (row[fieldmap["item"]] or "").strip()
                vendor = (row[fieldmap["vendor"]] or "").strip()
                pdate = (row[fieldmap["date"]] or "").strip()
                qty = float(row[fieldmap["qty"]])
                unit = (row[fieldmap["unit"]] or "").strip().lower()
                total = float(row[fieldmap["total"]])
                if not item:
                    raise ValueError("missing item name")

                match = find_ingredient_match(conn, item)
                if match:
                    ingredient_id, _, _ = match
                    matched += 1
                else:
                    inferred_base = "each" if unit in ("each", "case") or unit not in WEIGHT_TO_LB else "lb"
                    cur = conn.execute(
                        "INSERT INTO ingredients (name, base_unit, vendor, category) VALUES (?, ?, ?, ?)",
                        (item, inferred_base, vendor or None, "Imported"),
                    )
                    ingredient_id = cur.lastrowid
                    created += 1

                ing = conn.execute("SELECT * FROM ingredients WHERE id=?", (ingredient_id,)).fetchone()
                base_qty, base_unit, unit_price = normalize_purchase(ing["base_unit"], qty, unit, total)
                conn.execute(
                    """INSERT INTO purchases (ingredient_id, date, qty, unit, total_price, unit_price, source)
                       VALUES (?, ?, ?, ?, ?, ?, 'csv')""",
                    (ingredient_id, pdate, round(base_qty, 4), base_unit, round(total, 2), round(unit_price, 4)),
                )
            except Exception as e:  # noqa: BLE001 — per-row import errors are reported, not fatal
                errors.append({"row": i, "error": str(e)})
        conn.commit()
        return {"rows_processed": rows_processed, "created": created, "matched": matched, "errors": errors}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Recipes
# ---------------------------------------------------------------------------
@app.get("/api/recipes")
def list_recipes():
    conn = get_conn()
    try:
        rows = conn.execute("SELECT * FROM recipes ORDER BY name").fetchall()
        return [cost_recipe(conn, r) for r in rows]
    finally:
        conn.close()


@app.get("/api/recipes/{rid}")
def get_recipe(rid: int):
    conn = get_conn()
    try:
        row = conn.execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
        if not row:
            raise HTTPException(404, "recipe not found")
        return cost_recipe(conn, row)
    finally:
        conn.close()


@app.post("/api/recipes")
def create_recipe(r: RecipeIn):
    conn = get_conn()
    try:
        cur = conn.execute(
            "INSERT INTO recipes (name, menu_price, target_fc_pct) VALUES (?, ?, ?)",
            (r.name, r.menu_price, r.target_fc_pct),
        )
        rid = cur.lastrowid
        for it in r.items:
            conn.execute(
                "INSERT INTO recipe_items (recipe_id, ingredient_id, qty_base_units) VALUES (?, ?, ?)",
                (rid, it.ingredient_id, it.qty_base_units),
            )
        conn.commit()
        row = conn.execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
        return cost_recipe(conn, row)
    finally:
        conn.close()


@app.put("/api/recipes/{rid}")
def update_recipe(rid: int, r: RecipeIn):
    conn = get_conn()
    try:
        existing = conn.execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
        if not existing:
            raise HTTPException(404, "recipe not found")
        conn.execute(
            "UPDATE recipes SET name=?, menu_price=?, target_fc_pct=? WHERE id=?",
            (r.name, r.menu_price, r.target_fc_pct, rid),
        )
        conn.execute("DELETE FROM recipe_items WHERE recipe_id=?", (rid,))
        for it in r.items:
            conn.execute(
                "INSERT INTO recipe_items (recipe_id, ingredient_id, qty_base_units) VALUES (?, ?, ?)",
                (rid, it.ingredient_id, it.qty_base_units),
            )
        conn.commit()
        row = conn.execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
        return cost_recipe(conn, row)
    finally:
        conn.close()


@app.delete("/api/recipes/{rid}")
def delete_recipe(rid: int):
    conn = get_conn()
    try:
        conn.execute("DELETE FROM recipe_items WHERE recipe_id=?", (rid,))
        cur = conn.execute("DELETE FROM recipes WHERE id=?", (rid,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, "recipe not found")
        return {"deleted": True}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Invoices
# ---------------------------------------------------------------------------
@app.get("/api/invoices")
def list_invoices():
    conn = get_conn()
    try:
        rows = conn.execute("SELECT * FROM invoices ORDER BY uploaded_at DESC").fetchall()
        return [{**dict(r), "url": f"/uploads/{r['filename']}"} for r in rows]
    finally:
        conn.close()


@app.post("/api/invoices")
async def upload_invoice(file: UploadFile = File(...)):
    safe_stub = re.sub(r"[^A-Za-z0-9._-]", "_", file.filename or "invoice")
    now = datetime.now()
    safe_name = f"{now.strftime('%Y%m%d%H%M%S%f')}_{safe_stub}"
    path = os.path.join(UPLOAD_DIR, safe_name)
    content = await file.read()
    with open(path, "wb") as f:
        f.write(content)
    conn = get_conn()
    try:
        cur = conn.execute(
            "INSERT INTO invoices (filename, uploaded_at, status) VALUES (?, ?, 'manual')",
            (safe_name, now.isoformat()),
        )
        conn.commit()
        return {"id": cur.lastrowid, "filename": safe_name, "uploaded_at": now.isoformat(),
                "status": "manual", "url": f"/uploads/{safe_name}"}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
@app.get("/api/settings")
def read_settings():
    conn = get_conn()
    try:
        return get_settings(conn)
    finally:
        conn.close()


@app.put("/api/settings")
def write_settings(s: SettingsIn):
    conn = get_conn()
    try:
        if s.target_fc_pct is not None:
            set_setting(conn, "target_fc_pct", s.target_fc_pct)
        if s.drift_threshold_pct is not None:
            set_setting(conn, "drift_threshold_pct", s.drift_threshold_pct)
        if s.restaurant_name is not None:
            set_setting(conn, "restaurant_name", s.restaurant_name)
        conn.commit()
        return get_settings(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8321)
