# NEXT STEPS — CostSauce: from demo to fully live & operational

Ordered by dependency. Free tiers used wherever they exist; anything costing money or touching third parties is marked **[APPROVAL]**.

## Stage 1 — Public demo (this deployment)
- [x] GitHub repo: `travis112486/costsauce`
- [ ] Vercel deploy: static site at `/`, serverless FastAPI demo at `/demo` + `/api/*`, videos, recap
- [ ] **Known demo limitation:** SQLite seeds into `/tmp` per serverless instance — data resets on cold start. Fine for a demo; say so on the page.

## Stage 2 — Make it real (week 1–2)
1. **Domain** — `costsauce.com` / `costsauce.app` are unregistered (verified 2026-07-25). ~$12–15/yr. **[APPROVAL: purchase]**
2. **Persistent DB** — Neon (serverless Postgres, free tier) or Railway/Render free tier. Swap SQLite → Postgres (SQLAlchemy/DB layer already isolated; ~1 day).
3. **Auth** — per-restaurant accounts. Clerk or Supabase Auth free tiers cover the first 10k users. Magic-link email fits the ICP (owners on phones).
4. **Live CTA** — site buttons currently point at the demo. Add a real waitlist/beta signup (Tally or Formspree free tier) and pipe signups to the Notion lead board. **[APPROVAL: form goes live]**
5. **Custom domain on Vercel** — point the purchased domain; Vercel handles TLS.

## Stage 3 — The actual product loop (week 2–4)
6. **Invoice intake** — email-forward address (e.g. `invoices@in.costsauce.com` via Cloudflare Email Routing → worker) + photo upload endpoint.
7. **OCR/parsing** — v1: vision-LLM extraction (Claude/GPT-4o-mini, ~$0.002–0.01/invoice) into the existing ingredient/price schema; v0 fallback: the current manual photo-assisted entry. **[APPROVAL: LLM API spend, est. <$20/mo at pilot scale]**
8. **Alerting** — the drift engine exists; wire it to email via Resend free tier (100/day). The Weekly Drift Report template is already designed (`deliverables/drift-report-sample.html`).
9. **Billing** — Stripe checkout + customer portal (no fixed cost; 2.9% + 30¢/charge). Plans per `business/BUSINESS_MODEL.md`: $49 / $99 / $149. **[APPROVAL: Stripe account + live keys]**
10. **Telemetry** — instrument LLM/OCR calls with Latitude (already in the stack) + Sentry free tier for errors.

## Stage 4 — Launch (week 4–6) **[APPROVAL: all outreach]**
11. **Founder-led posts** — r/restaurateur, r/smallbusiness, Indie Hackers, 3–4 restaurant-owner Facebook groups. Lead with the free calculator + the two videos. Follow `deliverables/onboarding-emails.md` for the trial sequence.
12. **Pilot cohort** — 10 independent owners, white-glove onboarding, price locked at $29/mo founding rate for testimonials.
13. **Bookkeeper channel** — pitch 5 restaurant-serving bookkeepers the multi-client tier.
14. **SEO wedge** — the free food-cost calculator as a standalone indexable tool page.

## Stage 5 — Business hygiene
15. **Legal** — entity, ToS + privacy page, DPA if handling invoices with vendor data (questions for counsel, not legal advice).
16. **Support surface** — `support@` mailbox + a 1-hour/week triage block.
17. **Kill criteria** (from the final review): if meez or Recipe Cost Calculator ships drift alerts under $120/mo, reassess positioning within 2 weeks.

## Effort estimate
Stages 2–3 are ~5–8 focused days of engineering on top of the existing codebase. The blocker items are all approvals, not unknowns.
