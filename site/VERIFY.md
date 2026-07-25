# CostSauce site — verification

Built: index.html, css/style.css, js/calculator.js. Assets untouched, referenced from existing `assets/`.

## Asset & link paths

Checked every `href`/`src` in `index.html` against the filesystem (script: resolve each local path, skip `http*`/`#`/`mailto:`):

```
OK   assets/logo-mark-v2.svg   (favicon)
OK   css/style.css
OK   assets/logo-mark-v2.svg   (nav brand mark)
OK   assets/img/hero-owner.png
OK   assets/icon-invoice.svg
OK   assets/icon-plate.svg
OK   assets/icon-alert.svg
OK   assets/img/product-dashboard.png
OK   assets/img/product-ingredients.png
OK   assets/img/product-recipes.png
OK   js/calculator.js
```

No 404s. All external links (Reddit threads, NRN, MarketMan, meez, Recipe Cost Calculator, Backbar) point to the exact URLs given in SITE_SPEC.md, used consistently in the Problem section, Pricing comparison line, Trust section, and Footer link list.

Verified in a live headless-Chromium render (Playwright) at 1440px and 390px: page loads with **zero console errors**, all four images render (hero + 3 product screenshots), all three feature icons render, nav hamburger opens/closes correctly on mobile, and `<details>` FAQ accordions expand.

## Copy fidelity

`copy.md` used verbatim for: hero H1/sub/CTA/microcopy, all four owner quotes, NRN stat line, "How it works" 3 steps, product screenshot H2 + captions, all three pricing tiers + line under table + comparison line, "What it doesn't do" H2 + all four bullets, calculator H2/sub, and all four FAQ Q&As. Footer evidence line and copyright line match spec exactly. Checked for the brand's banned words (revolutionize, empower, seamless, leverage, unlock, elevate, streamline, journey, game-changer, delve, landscape) — none present in HTML, CSS, or JS.

Sources cited exactly as specified in SITE_SPEC.md's URL list (r/restaurateur thread for the first three owner quotes, r/restaurantowners for the MarginEdge/$480 quote, NRN for the stat strip, MarketMan/meez/Recipe Cost Calculator/Backbar pricing pages in the footer and relevant sections).

## Calculator math

Formulas (`js/calculator.js`):
- Plate cost = Σ(qty × unit cost) across ingredient rows
- Food-cost % = plate cost / menu price × 100
- Suggested price @ 30% = plate cost / 0.30, rounded **up** to the nearest $0.50 (rounds to the nearest cent first to kill floating-point noise, so exact multiples of $0.50 are never bumped up)
- Verdict points = food-cost % − 30, rounded to 1 decimal
- Verdict $ = plate cost − (0.30 × menu price), i.e. the cost dollars not covered by a 30%-of-price budget

### Required spec test (verified live in browser via Playwright)

Input: 1 ingredient, qty 1 × $3.30 unit cost → plate cost $3.30; menu price $11.00

```
SPEC CHECK plate cost:      $3.30
SPEC CHECK food-cost%:      30.0%
SPEC CHECK suggested price: $11.00
SPEC CHECK verdict:         "Buffalo Wings — At $11.00, this dish lands right at a 30% food-cost target."
```

Matches spec exactly: 30.0% food cost, and the suggested price rounds to $11.00 (already on a $0.50 boundary, not pushed to $11.50 — confirms the round-up logic doesn't over-round exact boundaries).

### Additional cases checked (Node, pure-function unit tests + live browser interaction)

| Plate cost | Menu price | Food-cost % | Suggested @30% | Verdict |
|---|---|---|---|---|
| $5.14 (5.136) | $16.00 | 32.1% | $17.50 | "2.1 points over ... $0.34 lost per plate" — reproduces the spec's example sentence verbatim |
| $4.80 | $16.00 | 30.0% | $16.00 | on-target message, no "0.0 points" nonsense wording |
| $3.00 | $16.00 | 18.8% | $10.00 | under-target message, "extra margin per plate" |
| $6.00 | — | — | $20.00 | boundary case: exact $0.50 multiple not over-rounded |
| $6.60 | — | — | $22.00 | boundary case: exact $0.00 multiple not over-rounded |
| $4.65 | — | — | $15.50 | fractional boundary, correct despite float noise (4.65/0.3 = 15.500000000000002) |

### Live interaction test (Playwright, default seed data: Buffalo Wings, 3 ingredients, $16 menu price)

- Baseline plate cost: $5.70 (1.5×$3.00 + 0.3×$2.00 + 1×$0.60)
- Add ingredient row ("Ranch dip", qty 2, $0.50) → plate cost updates live to $6.70, verdict recalculates to "11.9 points over ... $1.90 lost per plate"
- Remove row → plate cost updates live to $2.20, row count decreases correctly
- Remove-button correctly disables when only one ingredient row remains (can't delete the last row)
- Zero/blank state (no menu price or no ingredient cost) shows a neutral prompt instead of a nonsensical percentage or verdict

## Responsive check (390px, 1440px)

Screenshots taken via headless Chromium at both widths for the full page and the calculator section specifically:
- Nav collapses to hamburger under 720px; toggle opens/closes a dropdown with all 4 links + CTA, confirmed via click simulation.
- Quote grid, steps grid, screenshot grid, and pricing grid collapse to a single column under 980px.
- Ingredient rows switch from a 5-column grid header to stacked mobile cards (name full-width, qty+unit paired, cost+remove paired) under 720px — confirmed by scrolled screenshot at 390px.
- Calculator app (`.calc-app`) stacks inputs above results under 980px.
- All text remains legible, no horizontal overflow observed at 390px.

## What wasn't tested

- Cross-browser (only Chromium was available in this environment). CSS uses standard flexbox/grid with no vendor-prefix-dependent features, so Firefox/Safari risk is low.
- No backend/server — this is a fully static, client-side-only page as specified. `calculator.js` has no external dependencies and works offline (verified no network calls are made beyond the initial Google Fonts stylesheet, which is optional/progressive — the page is fully usable if it fails to load).
