# CostSauce — Business Design (Phase 3)

*Status: POST-SKEPTIC REVISION (research/skeptic-c1.md verdict: WOUND → repositioned). Original "affordable restaurant COGS SaaS" framing killed; pivot below is the surviving thesis.*

## One-liner
**CostSauce is price-drift radar for independent restaurants:** forward your supplier invoices, and it tells you exactly which menu items stopped being profitable — before your margin does. Live plate costs, ingredient price history, and repricing alerts for under $100/mo.

## The sharpened problem (evidence: research/pain-occupational.md §1 + skeptic-c1.md)
- Owners fight food costs in spreadsheets that break: *"The formulas got fragile, my team broke them constantly."*
- Enterprise automation is priced for groups: MarginEdge $480/mo quote, xtraCHEF $300–350/mo, MarketMan automation tier $199–249/mo, meez real-time costing $199/mo (skeptic-fetched pricing pages).
- Cheap tools exist (RCC $29/mo, meez $24–119/mo, Backbar bars) BUT they are maintenance-heavy: manual price entry, chef-unfriendly setup, or bar-only. Nobody under $199/mo automates **invoice → price history → which-menu-items-broke** for food-heavy single-location independents.
- Market context (skeptic-fetched): 412,498 independent US locations (NRN/Technomic 2025); 82% of operators saw higher food costs in 2025; food costs >35% above pre-pandemic levels; cost is the #1 barrier to tech adoption. Pain is real; willingness requires fast visible ROI and low friction.

## ICP (beachhead)
Independent, single-location (1–3) US **food-heavy** restaurants ($500k–$2M revenue), owner-operator who still sees supplier invoices, currently spreadsheet-or-nothing. NOT bars (Backbar owns beverage), NOT chains/groups (MarginEdge/R365's turf).

## Product (MVP core loop — deliberately constrained per skeptic)
1. **Ingest:** supplier invoice via photo upload, email-forward capture (unique inbound address shown in-app; v1 parses manually confirmed entries), CSV order-guide import, or 20-second manual quick-entry. Photo-assisted entry: invoice image shown beside the entry form.
2. **Normalize:** ingredients mapped to base units (lb/each/case→unit price), duplicate-name merging ("CHKN BRST BNLS" = "chicken breast boneless").
3. **Cost:** recipes = ingredient quantities → live plate cost + food-cost % vs menu price.
4. **Alert:** price-drift radar — "% change vs trailing average" per ingredient; menu items whose food-cost % crossed the owner's target; "reprice suggestion" to restore margin.
5. **Dashboard:** top price movers, most dangerous menu items, margin at a glance.

Explicitly OUT (honest scope): POS integration, supplier EDI, full inventory counts, payroll/accounting. Future paid add-ons — never promised in base tier (skeptic constraint honored).

## Business model
- **Starter $49/mo:** 1 location, 30 invoices/mo, 25 recipes, drift alerts, dashboard.
- **Growth $99/mo:** unlimited invoices + recipes, vendor price comparison, CSV exports.
- **Pro $149/mo:** up to 3 locations, priority parsing, multi-user.
- 14-day trial, monthly billing (skeptic: stressed owners fear lock-in), optional annual -20%.
- ROI framing: independent at $80k/mo revenue, ~30% food cost = $24k/mo of food; catching a 2-point drift = $1,600/mo. Any single alert pays for a year of Starter.

## GTM (first 90 days, $0)
1. Founder-led in r/restaurateur, r/restaurantowners, FB restaurant-owner groups: help-first pricing/costing advice, tool in profile (the exact communities the pain evidence came from).
2. **Free wedge tool:** public Food Cost Calculator (no signup; computes plate cost + food-cost %, emails/exports the result) → top-of-funnel capture of the exact ICP. BUILT as part of this package.
3. Bookkeeper/accountant channel (skeptic's defensibility suggestion): restaurant bookkeepers manage the invoice flow already; offer them a partner dashboard.
4. Design-partner program: 5 owners from complaint-thread ecosystems, white-glove onboarding, testimonials.

## Why now
Food costs >35% above pre-pandemic (NRN 2025); 82% of operators hit by rising food costs while enterprise vendors race up-market and cheap tools stay manual; phone-camera invoice capture is now normal ops behavior.

## Unit economics sketch (labeled assumptions)
- CAC: founder-led + free-tool + bookkeeper channel → <$150 blended (assumption).
- Gross margin ~85% (assumption). Churn mitigations: weekly drift digest email = recurring value touch; seasonal-pause plan; month-to-month pricing.
- 100 customers @ ~$79 avg = $7.9k MRR; 500 = $39.5k MRR. Niche ceiling exists (skeptic: TAM real but attention competes with POS/labor buys) — acceptable for a bootstrapped launch; expansion path = bookkeeper channel + add-ons.

## Competitive map (post-skeptic, fetched URLs in skeptic-c1.md)
| Tool | Price | Why we don't fight it head-on |
|---|---|---|
| MarginEdge / xtraCHEF / R365 | $300–480/mo | Enterprise groups; our ICP can't justify them |
| MarketMan | $199–249/mo | Automation floor; we undercut with constrained scope |
| meez | $24–199/mo | Chef recipe tool; real-time costing is $199; we own *drift alerts for owners* |
| Recipe Cost Calculator | $29/mo | Manual recipe costing since 2012; no automated invoice radar |
| Backbar | $0–149/mo | Bars/beverage. We explicitly don't target bars |
| Culvana | $199/loc/mo | AI-native full platform; 2–4× our price |
| **Spreadsheets** | free | The real incumbent: breaks, blind to drift, no alerts |

Positioning sentence (post-pivot): *"RCC and meez help chefs cost recipes. CostSauce watches your invoices and warns owners when a recipe stops making money."*

## Name & domain
**CostSauce** — costsauce.com + costsauce.app unregistered per RDAP 404 checks 2026-07-25 (checked, NOT purchased per guardrails). Tagline: **"The secret sauce is knowing your costs."**
