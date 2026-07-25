# BUILD LOG — Company Builder Experiment, Run 1

Orchestrator: HERMES PRIME (Kimi K3 driving; Claude CLI + subagents as domain workers; skeptic passes by orchestrator + dedicated skeptic agents)
Started: 2026-07-25 (UTC)

## Gate 1 — Scope (stated before work)

**Done =** a stranger opens `recap.html`, understands the business in 5 minutes, can run the site locally, can watch the launch + founder videos, and walks away convinced — or precisely informed about why not. Plus: every claim traces to a real fetched URL; site screenshot-verified mobile+desktop; videos rendered AND watched; build log holds every self-answered question; git tree clean.

### Known
- Workspace: `/opt/data/projects/company-builder-experiment/run-1/`, git initialized, strict `.gitignore`.
- Tooling verified present: `claude` CLI v2.1.216 (Claude Max auth), node, npm, uv, ffmpeg, python3.
- Higgsfield CLI + MCP: authenticated existing subscription (image + video generation) — NOT new spending.
- No media API keys (Kie.ai / ElevenLabs / HeyGen) exist in any `.env` on this machine (verified by scanning all 7 `.env` files).

### Assumed (defaults picked, logged)
- **A1:** "APIs whose keys already exist in .env" — those keys don't exist, so those services are OUT. Substitute: Higgsfield (existing authed subscription) for image/video, free local/edge TTS for voice, ffmpeg for assembly. Rationale: guardrail says no NEW spending; using existing authed tools is within spirit and letter.
- **A2:** Target geography/language: English-language, US-centric market (largest evidence pool of complaints, easiest verification).
- **A3:** "Product" = a real, runnable software artifact (web app), not a mockup — the mission says "build the product". Scope: functional core loop, local-first.
- **A4:** Business model must be launchable this month by one person with no capital — rules out hardware, marketplaces needing two-sided cold start, regulated fintech/health.
- **A5:** Budget of effort: ship the strong 80% per phase rather than perfect 100% late.

### Load-bearing unknowns (attack first, cheapest probe)
- U1: Which pains are real, frequent, and underserved *right now*? → Parallel research swarm with mandatory URL evidence.
- U2: Can Higgsfield generate usable brand/product imagery? → Probe early in brand phase before depending on it.
- U3: Can we produce a watchable video with ffmpeg + TTS + generated stills/clips? → Probe with a 10-second test render before committing.

## Self-answered questions
- **Q: No ElevenLabs/HeyGen/Kie keys — how do we make videos?** A: Higgsfield (existing subscription) for visuals + edge-tts/piper (free) for voiceover + ffmpeg assembly. "Founder video" becomes a narrated founder-story video with AI voice + motion visuals instead of a HeyGen avatar. Logged as substitution, not a blocker.
- **Q: May I ask the user anything?** A: No — standing instruction: answer every question myself and log it.

---

## Phase log (appended as work completes)

### Phase 0 — Initialize (DONE, commit 54cd6ac)
Repo, .gitignore, dir skeleton, this log.

### Load-bearing unknown resolution (2026-07-25 11:17 UTC)
- **U2 RESOLVED ✓** Higgsfield CLI authed (travis1124@gmail.com, ultra plan, 510.9 credits). Probe: `z_image` generated a brand-style icon (receipt→shield, teal/amber) → downloaded → verified valid 4.6MB PNG → vision-checked: rated "Usable, professional brand artwork". Evidence: `evidence/image-probe.png`.
- **U3 RESOLVED ✓** Voice: Hermes built-in TTS (edge provider, free, no key) produced valid 7.56s mp3 (`evidence/tts-probe.mp3`, ffprobe-verified). Assembly: ffmpeg present. Video clips: Higgsfield `seedance_2_0` available when needed (deferred probe to Phase 6 — cheapest order).
- **Q (self-answered):** Do credits on Higgsfield count as "new spending"? A: No — pre-existing paid subscription already owned; guardrail prohibits NEW spend. Using owned quota ≠ new purchase. Same class as the mission's own "keys that already exist" allowance.
- **Q:** What are "my voice rules" for the founder script? A: No explicit rule set exists in this workspace. Default applied: the `humanizer` skill standard — plain words, short sentences, first-person specifics, zero AI-isms ("delve", "landscape", "game-changer", "unlock", "elevate", "journey" etc.), no hype claims, concrete numbers only. Logged as assumption A6.

### Phase 1 — Hunt for pain (DONE)
3 parallel researchers (solopreneur / consumer / occupational), 12 candidate pains, every claim tied to fetched URLs. Files: research/pain-*.md. Strongest signals: restaurant COGS spreadsheet breakage (occupational), GBP suspensions (solopreneur), freelancer nonpayment (solopreneur), job-search ghosting (consumer).

### Phase 2 — Tournament (DONE)
Judged on 7-dimension weighted scorecard (research/TOURNAMENT.md). Winner: **C1 Restaurant COGS for independents (9.0/10)**; runner-up A1 GBP rescue (8.0) killed at finalist stage (outcome controlled by Google, episodic usage, service-shaped). Skeptic pass on C1: **WOUND** — competitor scan found affordable incumbents (Backbar/meez/RCC/MarketMan, all with fetched pricing URLs). **Re-decision: survive with pivot** → "invoice price-drift radar + recipe recosting" for food-heavy single-location independents; no POS/EDI promises; avoid bars. This pivot NARROWED the product and made it more buildable, not less.

### Phase 3 — Business design (DONE)
business/BUSINESS_MODEL.md (post-skeptic revision). Pricing $49/$99/$149, ICP = food-heavy single-location indies, GTM = founder-led communities + free calculator wedge + bookkeeper channel. Name: **CostSauce** (costsauce.com/.app RDAP-verified unregistered 2026-07-25, NOT purchased per guardrails).

### Phase 4 — Brand (DONE)
Logo v1 rejected by vision review (ladle unreadable); v2 approved (ladle drizzling $-shaped sauce onto plate, teal/amber). Assets in brand/: logo-mark-v2.svg, 3 vector feature icons, hero-owner.png, BRAND.md voice guide.

### Phase 5 — Build (DONE)
- Product: Claude CLI (domain worker) from business/PRODUCT_SPEC.md → FastAPI + SQLite app, seeded demo "The Copper Ladle". First run hit my 600s foreground timeout mid-build — resumed with `claude --continue` in background. Orchestrator-verified independently (never trust the builder's self-report): booted server, checked /api/dashboard (4 alerts incl. Lime +31%, 8 recipes costed), browser-checked 3 tabs (8.5/10, no glitches), screenshots saved.
- Site: Claude CLI from business/SITE_SPEC.md (hit max-turns but all sections complete). Verified: all assets 200; calculator math tested live ($5.70/$16 → 35.6%, suggest $19.00, $0.90/plate — correct); desktop + 390px mobile screenshots. Two glitches found by vision review, fixed by orchestrator: hero face-crop (object-position), product mobile table overflow (min-width:0). Recap mobile table overflow also found+fixed.
- **Q (self-answered):** site/founder voice? A: humanizer skill (34 banned-pattern rules) loaded and applied — numbers over adjectives, no hype.

### Phases 6–7 — Videos (DONE)
- 12 Higgsfield frame generations FAILED in batch script (URL extraction broke) — pivoted to zero-credit local composition (user directive mid-run: conserve credits): PIL brand cards + real product screenshots + 2 generated stills + composed endcards. 16 TTS beats (edge), seed_audio music looped, make_video.py assembled launch.mp4 (61.8s) + founder.mp4 (93.8s).
- Gate 4 watch-verification (frame grids + volumedetect): launch clean; founder had REAL glitch — captions duplicated stat-card text on 5 slides. Fixed (captions only on text-free visuals), re-rendered, re-verified clean.
- **Q (self-answered):** fictional founder vs "invent nothing"? A: persona disclosed as fictional in script header + recap + teaser; every market claim in scripts is sourced. Creative framing ≠ fabricated evidence.

### Phase 8 — Kill pass (DONE, research/final-review.md)
Orchestrator (Kimi K3, skeptic-class per routing): 7 attacks, all answered or disclosed. Top unfixed risk: meez/RCC moving down-market. Live-URL check: 5×200; 2×Reddit 403 to curl (bot wall — links real, fetched by research agents during hunt).

### Phase 9 — Package (DONE)
recap.html: 5-minute stranger test — business, run instructions, embedded videos, deliverables map, kill-pass summary, guardrails/provenance. Verified: videos play (readyState 4), images render, no mobile overflow. Ad creative vision-verified (no garbled AI text). Deliverables beyond floor: Freezer Sheet PDF (the unexpected one), onboarding sequence, drift-report sample, investor teaser, ad creative.

## DEFINITION OF DONE — graded (research/final-review.md §DoD)
All items PASS. Working tree clean after final commit.

## Phase 10 — GO LIVE (2026-07-25, post-experiment, user-approved)
- GitHub repo created via Composio GitHub connection: travis112486/costsauce (71 files, byte-verified; mp4s + >5MB binaries excluded per API limits; big PNGs recompressed to JPEG, refs updated)
- Vercel CLI 57.0.0 (user-local npm prefix); device-code auth (user-approved)
- deploy/ package (Claude-built, orchestrator-verified): FastAPI serverless + /tmp SQLite seeding (VERCEL=1), marketing at /, product at /demo
- Fixed Vercel FastAPI preset quirk: preset routes / to the function, shadowing public/index.html — marketing page now served by the function route itself (marketing.html)
- 5 deployments total (routing iterations) → LIVE: https://costsauce.vercel.app
- Verified live via Playwright + API: marketing headline, hero .jpg, calculator recomputes ($5.70 plate / 35.6%), demo alerts render, videos stream 206, API 4 alerts + 8 items
- Duplicate debug project 'deploy' removed from Vercel; canonical project: travis112486s-projects/costsauce
