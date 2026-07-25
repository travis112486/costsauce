# CostSauce marketing site build spec

Build a STATIC marketing site in /opt/data/projects/company-builder-experiment/run-1/site/ (index.html + css in place; assets already exist).

## Inputs (read these first)
- site/copy.md — ALL copy. Use it nearly verbatim; do not invent new claims, stats, or quotes. Where copy references a source URL, use the real URLs below.
- brand/BRAND.md — palette/fonts/voice.
- site/assets/logo-mark-v2.svg, icon-invoice.svg, icon-plate.svg, icon-alert.svg
- site/assets/img/hero-owner.png (hero illustration)
- site/assets/img/product-dashboard.png, product-ingredients.png, product-recipes.png (REAL product screenshots — feature them prominently in an "This is the actual product" section with browser-chrome frames)

## Source URLs for the cited quotes/stats (use exactly these as hrefs)
- "I've spent way too many nights..." / spreadsheet / $300-350 quotes: https://www.reddit.com/r/restaurateur/comments/1l845fu/im_a_fellow_restaurant_owner_that_built_a_food/
- MarginEdge $480 quote: https://www.reddit.com/r/restaurantowners/comments/1jvuw2i/frustrated_between_choosing_from_bar_vs/
- "keeping the cost less than 200": same restaurantowners URL above
- NRN stats (82% food costs up, 412,498 independents): https://www.nrn.com/independent-restaurants/the-independent-restaurant-sector-shrunk-by-2-3-in-2025
- MarketMan $199: https://www.marketman.com/pricing-for-restaurant-inventory-management-system
- meez: https://www.getmeez.com/pricing ; RCC: https://recipecostcalculator.net/ ; Backbar: https://www.getbackbar.com/pricing

## Required sections (in order)
1. Sticky nav: logo + "CostSauce", links: Product, Pricing, Free calculator, FAQ; CTA button "Try the demo" (href #demo)
2. Hero: copy.md hero verbatim, hero-owner.png right side, primary CTA "See the live demo" + secondary "Free calculator"
3. Problem: the 4 owner quotes as styled quote-cards with source links, plus the NRN stat strip
4. How it works: 3 steps with the 3 vector icons (icon-invoice, icon-plate, icon-alert)
5. Product screenshots section (id="demo"): 3 screenshots in browser-chrome frames, captions from copy.md, plus a note "Demo restaurant: The Copper Ladle. Run it locally: uv run app.py — see README."
6. Pricing: 3 tiers from copy.md, comparison line under the table with links
7. "What CostSauce doesn't do (yet)" — trust section, copy.md verbatim
8. FREE CALCULATOR (id="calculator"): fully client-side interactive Food Cost Calculator. Inputs: item name, menu price, dynamic ingredient rows (name, qty, unit cost). Outputs updating live: plate cost, food-cost %, target 30% suggested price (rounded up to .50), verdict sentence ("At $16.00, this dish is 2.1 points over a 30% target — that's $0.34 lost per plate."). Polished, on-brand, works offline. This is the free wedge tool — make it genuinely good.
9. FAQ from copy.md
10. Footer: "Evidence: every claim on this page links to its source." + link list + "© 2026 CostSauce (concept demo — not a live business)"

## Rules
- Single index.html + css/style.css + js/calculator.js. Google Fonts Fraunces+Inter. Fully responsive (mobile 390px perfect). No external JS libs. No invented testimonials (only the sourced quotes). No lorem ipsum. Straight quotes not curly in code-visible text is fine either way.
- Verify: open index.html checks — all asset paths resolve (no 404s), calculator computes correctly (test: plate cost $3.30, menu $11 → 30.0%; suggestion rounds to .50 up). Write site/VERIFY.md with what you checked.
