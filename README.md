# CostSauce — price-drift radar for independent restaurants

Owners photograph or forward supplier invoices. CostSauce normalizes every price, ties them to their recipes, and alerts them when a dish stops making money — **with the price that fixes it**. No POS integration, no annual contract. $49/mo where incumbent automation starts at $199+.

This repository is the complete output of an autonomous company-builder run (2026-07-25): market research, adversarial tournament, skeptic-forced pivot, working product, brand system, marketing site, launch + founder videos, go-to-market deliverables, and a final kill pass. The orchestration log is in [BUILD_LOG.md](BUILD_LOG.md); the 5-minute summary is [recap.html](recap.html).

## Layout

| Path | What it is |
|---|---|
| `product/` | Working FastAPI + SQLite app (demo restaurant "The Copper Ladle"). `cd product && uv run app.py` → http://localhost:8321 |
| `site/` | Static marketing site + free interactive food-cost calculator (math verified). `cd site && python3 -m http.server 8322` |
| `brand/` | Logo (SVG), feature icons, palette, voice guide |
| `videos/` | Launch (62s) + founder (94s) videos — scripts, frames, assembly pipeline |
| `deliverables/` | Freezer Sheet PDF, onboarding email sequence, weekly Drift Report sample, investor one-pager, ad creative |
| `research/` | Evidence pack: 12 candidate pains, tournament scorecard, skeptic attack, final review |
| `business/` | Business model (post-skeptic revision), product + site specs |
| `evidence/` | Screenshots, tool probes, build logs |

## Honesty notes

- Every market claim traces to a fetched URL (see `research/`). Reddit links 403 to curl (bot wall) but are real threads.
- The founder persona in the founder video is **fictional creative work**, disclosed in the script and recap.
- The product is a verified local demo (seeded data), not a hosted multi-tenant SaaS — productionizing steps are in `NEXT_STEPS.md`.
- The two rendered videos (`videos/launch.mp4`, `videos/founder.mp4`) are excluded from this repo (API push size limits); they ship with the Vercel deployment and the local workspace.

## Provenance

Built by HERMES PRIME (Kimi K3) orchestrating Claude CLI build agents, research subagents, Higgsfield (imagery/music), and edge TTS — zero new spending, nothing published outside this repo.
