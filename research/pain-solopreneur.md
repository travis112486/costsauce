# Pain reports: solopreneurs, freelancers, and small business owners (2025-2026)

Researcher: A (solopreneur / small-business angle)  
Scope: Reddit r/smallbusiness, r/freelance, r/sweatystartup, r/webdev; Hacker News; Indie Hackers.  
Method note: every URL cited below was fetched with `web_extract`. Reddit's extracted pages exposed post bodies but generally not comment bodies or reliable vote/comment counts, so Reddit upvote/comment counts are marked **UNVERIFIED** unless visible in fetched text. Frequency signals for Reddit pains are therefore based primarily on multiple independent fetched threads and the dates visible in the fetched pages.

## Ranked shortlist by evidence strength

1. **Google Business Profile suspension / review vaporization for local service businesses** — strongest intensity: direct revenue loss claims ($35k/month from GBP), threat of lawsuit, multiple 2025 threads from service businesses.
2. **Paid local lead-gen platforms (Yelp / Angi / Thumbtack / 411local) produce expensive, low-quality or scammy leads** — strongest willingness-to-pay: owners already paying $30-$61/lead, hundreds/month, multi-tool stacks, yet complaining results don't justify cost.
3. **Small-business bookkeeping/invoicing software is too expensive, confusing, and accountant-captured** — strong frequency across several 2025 threads; explicit prices ($61/mo, $100/mo, $1,500 bookkeeper) and many alternatives considered but no obvious fit.
4. **Freelancer client-payment / contract / project-admin breakdowns** — strong qualitative pain (months unpaid, small claims court, exploited creative work) plus visible demand for replacement freelancer CRM/invoicing after Fiverr Workspace shutdown; WTP is weaker but real (legal action, paid tools/workflows).

---

## 1) Google Business Profile suspension / review vaporization

### Candidate business problem
Local service businesses depend heavily on Google Maps/Business Profile for discovery and reviews, but legitimate profiles can be suspended or disabled with opaque reasons, slow appeals, and large revenue/reputation impact. A productized rescue / compliance / evidence-pack / monitoring service for service-area businesses may have demand.

### Who exactly suffers
- Local service-area businesses: DJs, movers, HVAC, contractors, home-office/shop trades.
- Especially businesses without a traditional storefront, whose profiles are vulnerable to address/service-area rule enforcement.

### Verbatim complaint quotes
1. DJ company owner:  
   > "We've been in business for 20 years, we had just shy of 200 5 star reviews, and now they're all gone."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1hzxiwn/google_pulled_down_my_business_profile_and_i_dont/

2. Same DJ company owner:  
   > "I'm so frustrated that they can just vaporize our business profile like this with zero warning, this is the time of year when we typically book lots of weddings and this will put us at a serious disadvantage. Going to lose a lot of money because of this."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1hzxiwn/google_pulled_down_my_business_profile_and_i_dont/

3. Moving company owner:  
   > "Our **Google Business Profile was suspended without clear reason**, even though we are a legitimate, woman-owned moving company. Before suspension, our profile brought in around 10 jobs a month (~$35,000 in revenue)."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1ntxfi7/google_suspended_our_legit_business_profile/

4. New HVAC owner:  
   > "After a minute of being listed it suspended me stating \"deceptive content\". I appealed with my business registration with the state and a few pictures but that was 6 days ago and it still just shows my appeal has been \"submitted\"."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1jpc0z7/google_suspended_my_business_page_immediately/

### Frequency / intensity signals
- Multiple independent fetched Reddit threads in r/smallbusiness during 2025 (Jan 12, Apr 2, Sep 29 as visible on fetched Reddit pages/top-post date blocks):
  - DJ company profile disabled: https://www.reddit.com/r/smallbusiness/comments/1hzxiwn/google_pulled_down_my_business_profile_and_i_dont/
  - HVAC company suspended immediately: https://www.reddit.com/r/smallbusiness/comments/1jpc0z7/google_suspended_my_business_page_immediately/
  - Canadian moving company suspended and considering legal action: https://www.reddit.com/r/smallbusiness/comments/1ntxfi7/google_suspended_our_legit_business_profile/
- High intensity: one owner claims about **10 jobs/month and ~$35,000 revenue** came through the profile; another had **189/just-shy-of-200 five-star reviews** temporarily gone; a third is planning to **file a lawsuit against Google**.
- Reddit vote/comment counts: **UNVERIFIED** because `web_extract` did not expose reliable counts beyond generic `0 0` chrome.

### Existing solutions people mention, and quoted weaknesses/prices
- Manual Google appeal with documents/photos:
  > "As soon as I got the email I uploaded our trade name registration and our current city of Edmonton business license."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1hzxiwn/google_pulled_down_my_business_profile_and_i_dont/

  Weakness: opaque and slow support:
  > "I click the link in the in the email and it gives absolutely no information about why they've done this."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1hzxiwn/google_pulled_down_my_business_profile_and_i_dont/

  > "I've reached out to Google, they said they'd get back to me in 24-48 hours. That was a week ago."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1hzxiwn/google_pulled_down_my_business_profile_and_i_dont/

- Appeals with registration and photos:
  > "I appealed with my business registration with the state and a few pictures but that was 6 days ago and it still just shows my appeal has been \"submitted\"."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1jpc0z7/google_suspended_my_business_page_immediately/

- Legal action / collective action:
  > "Because of the financial loss and reputational damage, we are now preparing to **file a lawsuit against Google**."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1ntxfi7/google_suspended_our_legit_business_profile/

### Willingness-to-pay signals
- Massive stated business value: moving company says GBP brought **~$35,000 revenue/month** before suspension.
- DJ company attributes years of review-building and wedding-season bookings to Google profile visibility.
- Legal action preparation indicates willingness to spend money/time if the profile cannot be restored.
- Businesses are already doing manual document gathering and appeals; a paid specialist/service that shortens downtime could be positioned against revenue-at-risk.

### Underserved angle / possible product direction
- Not generic SEO. Narrowly: **Google Business Profile suspension prevention + recovery for service-area businesses**.
- Features: policy checklist before edits, address/service-area risk audit, evidence packet builder, appeal wording, review/reply backup, downtime alerting, local-search fallback pages/ads during suspension.

---

## 2) Paid local lead-gen platforms are expensive and low quality for small service businesses

### Candidate business problem
Local trades/service businesses are paying Yelp, Angi, Thumbtack, 411local, Google Ads, and cold-email stacks for leads, but complain about scam/fake leads, high per-lead prices, poor conversion, low volume, and lack of trust. A more transparent local acquisition system, shared referral marketplace, or lead-quality audit/refund/attribution tool could compete where people already spend.

### Who exactly suffers
- Local service operators: environmental testing / mold consulting, cleaning businesses, plumbing businesses, general local service providers.
- New small operators who lack organic referrals and are forced into paid platforms early.

### Verbatim complaint quotes
1. Environmental testing founder:  
   > "I’m struggling to bring in organic customers without relying on Angi or Thumbtack (which is pretty much how I’m surviving right now)."  
   Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

2. Same founder, with prices:  
   > "Angi leads are expensive ($61 each and about 40% of them fall through). Thumbtack is cheaper ($30), but the lead volume is low."  
   Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

3. Same founder, tool weaknesses:  
   > "Here’s what I’ve tried so far: • Social media: Low conversion rate. • Angi’s List: Most leads so far but not consistent — way too expensive. • Thumbtack: Too few leads. • Google Ads: Poor conversion for the monthly spend. • 411local: Straight-up scam. Took my money for 3 months with nothing to show."  
   Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

4. Yelp advertiser:  
   > "I continuously return to get burned by scammers from India and Bangladesh that just click the Ads and cost me hundreds of dollars per month."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1p55vz1/should_i_stop_dumping_funds_into_yelp/

5. Yelp business-page owner:  
   > "I opened my Yelp business page in August 2022 and initially tried their paid advertising service, but it led to nothing but robotic, fake leads."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1hw5uy2/stay_away_from_yelp/

### Frequency / intensity signals
- Multiple independent fetched threads across r/sweatystartup and r/smallbusiness in 2025:
  - Environmental testing company: Angi/Thumbtack/Google Ads/411local failures.
  - Cleaning business owners: Thumbtack effective but very expensive.
  - Yelp warnings: fake/robotic/scam leads and hundreds/month spend.
  - Plumbing owner evaluating Angi Leads shows ongoing demand: https://www.reddit.com/r/smallbusiness/comments/1lsyfy9/angi_leads/
- High intensity: explicit prices per lead ($61 Angi, $30 Thumbtack), fall-through rate (~40%), and a 3-month failed paid vendor relationship.
- Reddit vote/comment counts: **UNVERIFIED** due extraction limitations.

### Existing solutions people mention, and quoted weaknesses/prices
- Angi:
  > "Angi leads are expensive ($61 each and about 40% of them fall through)."  
  Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

- Thumbtack:
  > "Thumbtack is cheaper ($30), but the lead volume is low."  
  Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

  > "I personally have been running advertisements through thumbtack for a while now and yes, it’s pretty effective but very expensive."  
  Source: https://www.reddit.com/r/sweatystartup/comments/1lao8y4/cleaning_business_owners/

- Google Ads:
  > "Google Ads: Poor conversion for the monthly spend."  
  Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

- 411local:
  > "411local: Straight-up scam. Took my money for 3 months with nothing to show."  
  Source: https://www.reddit.com/r/sweatystartup/comments/1nzo4v0/environmental_testing_company/

- Yelp Ads:
  > "paid advertising service... led to nothing but robotic, fake leads"  
  Source: https://www.reddit.com/r/smallbusiness/comments/1hw5uy2/stay_away_from_yelp/

  > "cost me hundreds of dollars per month"  
  Source: https://www.reddit.com/r/smallbusiness/comments/1p55vz1/should_i_stop_dumping_funds_into_yelp/

- Cold email stack for a cleaning startup:
  > "Technology stack is DnB Hoovers for leads, skrapp.io for email verification, Instantly.ai/leadwarm.ai for warmup/campaign send, google workspace, 6 domains, 18 inboxes, spf, dkim, dmarc all setup"  
  Source: https://www.reddit.com/r/sweatystartup/comments/1ibvcbq/starting_a_cleaning_business_open_to_advice/

### Willingness-to-pay signals
- Already paying per-lead: $61/lead Angi, $30/lead Thumbtack, hundreds/month Yelp, paid Google Ads, paid 411local for 3 months.
- New cleaning business has a sophisticated paid outbound stack (D&B Hoovers, Skrapp, Instantly/Leadwarm, Google Workspace, 6 domains, 18 inboxes), indicating budget and willingness to use tools if they produce clients.
- Plumbing owner is actively evaluating Angi Leads, showing demand persists despite bad experiences.

### Underserved angle / possible product direction
- Not another generic marketing agency. Narrowly: **lead quality/ROI control and alternative acquisition for local service providers**.
- Possible wedges: validated local-intent lead marketplace; pay-on-booked-job not pay-per-lead; anti-scam click/lead filtering; missed-call-to-booking workflows; contractor/plumber/property-manager referral network; local landing pages + GBP-safe review capture.

---

## 3) Small-business bookkeeping/invoicing software is expensive, confusing, and accountant-captured

### Candidate business problem
Solo owners and tiny businesses need basic invoicing, estimates, AP/AR, tax/bookkeeping, and payments, but QuickBooks is perceived as overpriced, laggy, confusing, and sometimes forced by accountants. Alternatives each have a fatal tradeoff: free but missing bank sync, robust but hard, tax-weak, no upgrade path, or not real accounting.

### Who exactly suffers
- Sole proprietorships, one-person LLCs, handyman side businesses, real estate marketers, very small employers.
- Owners who are not accountants and need software that fits a small scale without enterprise pricing/complexity.

### Verbatim complaint quotes
1. Real estate marketer / small-business owner:  
   > "I can give you guys a laundry list on what is wrong with Quickbooks, but if that were the case, we would be here for hours wouldn’t we?"  
   Source: https://www.reddit.com/r/smallbusiness/comments/1mk2v42/small_business_owner_here_any_good_alternatives/

2. Same owner:  
   > "I just want a good invoicing platform alternative to quickbooks for a small business owner like me. A software with an app that will allow me to track my business finances and send invoices. Especially one that doesn’t lie to me or send extra charges to my clients without letting me know first!"  
   Source: https://www.reddit.com/r/smallbusiness/comments/1mk2v42/small_business_owner_here_any_good_alternatives/

3. QBO user with accountant lock-in:  
   > "My accountant uses QBO for all of their clients, so I don’t have another option unless I want to find a new accountant."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1lunl0y/why_does_quickbooks_online_just_keep_going_up/

4. Same QBO user on price/performance:  
   > "It is going up to $61/mo with her discount, when we started 5 years ago with her, it was $30/mo, so more than doubled, and it’s still as laggy, inept and frustrating as before."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1lunl0y/why_does_quickbooks_online_just_keep_going_up/

5. New incorporated owner:  
   > "she's now telling me that I should get quickbooks, which will cost an additional monthly $100 (after three months at $50)... $100/month is NOT a small expense for me."  
   Source: https://www.reddit.com/r/smallbusiness/comments/1nzyoxl/should_my_bookkeeper_require_me_to_get_quickbooks/

### Frequency / intensity signals
- Multiple independent r/smallbusiness threads in 2025 about QuickBooks alternatives/pricing/accountant requirements:
  - Alternative requested by real estate marketer: https://www.reddit.com/r/smallbusiness/comments/1mk2v42/small_business_owner_here_any_good_alternatives/
  - QBO price increase: https://www.reddit.com/r/smallbusiness/comments/1lunl0y/why_does_quickbooks_online_just_keep_going_up/
  - Sole proprietorship alternative request: https://www.reddit.com/r/smallbusiness/comments/1lm9h74/quickbooks_alternative/
  - Bookkeeper requiring QBO: https://www.reddit.com/r/smallbusiness/comments/1nzyoxl/should_my_bookkeeper_require_me_to_get_quickbooks/
  - New handyman business comparing options: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/
- Intensity: price doubled from $30 to $61/mo; another owner faces $100/mo software on top of a $1,500/6-month bookkeeper; post language includes "laggy, inept and frustrating" and "NOT a small expense."
- Reddit vote/comment counts: **UNVERIFIED** due extraction limitations.

### Existing solutions people mention, and quoted weaknesses/prices
- QuickBooks Online / Simple Start / Solopreneur:
  > "Quickbooks Simple Start: Mostly seems like the premium option, but it's expensive. I know some people hate it too."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

  > "Quickbooks Solopreneur: Seems like maybe a middle ground between cheap and good, but people seem to hate it on reddit, and it looks like there's no easy upgrade path if I ever want to move out of it."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

- Wave:
  > "Wave: People on reddit **REALLY** seem to hate it recently. Attractive that it's free, although the free version at this point does not integrate with a bank account."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

- Xero:
  > "Xero: Haven't seen it listed as much. Base plan is same price as Solopreneur, and from what I gather is less geared toward taxes"  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

- Zoho Books:
  > "Zoho Books: From what I understand, free (at my scale) and very robust, but not easy."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

- Square:
  > "Square: Great for payments, even invoices and receipts, but looks like it doesn't really do accounting."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

- Spreadsheets:
  > "Spreadsheet: Pretty much everybody says this isn't worth it. Everything is super manual, can't do invoices / receipts, etc."  
  Source: https://www.reddit.com/r/smallbusiness/comments/1m5ywd8/accounting_software_recommendation/

### Willingness-to-pay signals
- Owners are already paying or being asked to pay:
  - $61/mo QBO with accountant discount.
  - $100/mo QBO after intro period, on top of $1,500 for 6 months of bookkeeping.
  - Owners are considering paid tools for invoicing, estimates, AP/AR, online billing/payments, purchase orders.
- Existing spend is painful but persistent because accountants standardize on QBO and switching accountants is high-friction.

### Underserved angle / possible product direction
- Avoid generic accounting SaaS. Potential niche: **accountant-friendly, tiny-business bookkeeping/invoicing layer** that exports clean packets to accountants without forcing full QBO, or a "solo trades bookkeeping starter" with taxes, mileage, receipts, estimates, AP/AR, and guided upgrade path.
- Wedge could also be a **QBO cost-reduction / migration advisor** for microbusinesses, but defensibility may be weak unless tied to accountant workflows.

---

## 4) Freelancer client-payment, contracts, and admin breakdowns

### Candidate business problem
Freelancers, especially creative professionals, are losing money/time because clients pay late, withhold payment to demand extra deliverables, or exploit unclear contracts and working-file ownership. At the same time, a known freelancer back-office tool (Fiverr Workspace / AND.CO) is shutting down in 2026, creating migration pain for invoices/contracts/proposals/client info.

### Who exactly suffers
- Freelance creatives: designers, strategists, art directors, photographers, developers, solo consultants.
- Freelancers who manage proposals, contracts, client information, invoices, recurring invoices, and payment links themselves.

### Verbatim complaint quotes
1. Freelancer with unpaid client:  
   > "The client agreed but now it's months been since 28th March and still nothing."  
   Source: https://www.reddit.com/r/freelance/comments/1l25hlw/my_clients_are_not_paying/

2. Same freelancer asking how to prevent this:  
   > "What are some things I should avoid for future to make sure the client pays on time. I am going to start sending reminders 7 days before invoice is due, 3 days and over due."  
   Source: https://www.reddit.com/r/freelance/comments/1l25hlw/my_clients_are_not_paying/

3. Creative professional / art director:  
   > "But when I submitted my final invoice, the owner refused to pay unless I handed over all my working files. Files that were never part of the agreement, never needed … until after they replaced me with a new agency."  
   Source: https://www.reddit.com/r/freelance/comments/1l1vhwi/i_filed_a_legal_claim_after_being_unpaid_for_work/

4. Same creative professional:  
   > "Instead of paying, they stalled. Dismissed my emails. Tried to bully me into silence and extort my original working files with vehement refusal to pay my invoice."  
   Source: https://www.reddit.com/r/freelance/comments/1l1vhwi/i_filed_a_legal_claim_after_being_unpaid_for_work/

5. Same creative professional update:  
   > "They’re running Facebook ads using my work — creative direction, photography and language/tone from the unpaid project."  
   Source: https://www.reddit.com/r/freelance/comments/1l1vhwi/i_filed_a_legal_claim_after_being_unpaid_for_work/

6. Fiverr Workspace shutdown/migration pain:  
   > "Fiverr Workspace (formerly AND.CO) is being discontinued on March 1, 2026. If you used it for invoices / contracts / proposals / client info, make sure you export everything before the cutoff (mobile export isn’t supported)."  
   Source: https://www.reddit.com/r/freelance/comments/1rh8naj/psa_fiverr_workspace_andco_shuts_down_march_1/

### Frequency / intensity signals
- Multiple independent r/freelance threads in 2025-2026:
  - Client not paying months after invoice/work: https://www.reddit.com/r/freelance/comments/1l25hlw/my_clients_are_not_paying/
  - Legal claim over unpaid creative work/working files: https://www.reddit.com/r/freelance/comments/1l1vhwi/i_filed_a_legal_claim_after_being_unpaid_for_work/
  - Fiverr Workspace/AND.CO shutdown March 1, 2026: https://www.reddit.com/r/freelance/comments/1rh8naj/psa_fiverr_workspace_andco_shuts_down_march_1/
- Indie Hackers freelancer workflow post (1 like, 1 comment visible in fetched text) quantifies overhead:
  > "When you switch between all these things, you lose 2 hours every day. That’s around 60 hours a month. If your hourly rate is $20, that’s $1200 gone without noticing."  
  Source: https://www.indiehackers.com/post/saving-extra-1200-and60-hours-in-1-month-38e0e4fefe
- Reddit vote/comment counts: **UNVERIFIED** due extraction limitations.

### Existing solutions people mention, and quoted weaknesses/prices
- Reminder workflows:
  > "I am going to start sending reminders 7 days before invoice is due, 3 days and over due."  
  Source: https://www.reddit.com/r/freelance/comments/1l25hlw/my_clients_are_not_paying/

  Weakness: reactive; does not prevent clients from withholding final invoice or demanding files.

- Small Claims Court:
  > "I filed a Small Claims Court case."  
  Source: https://www.reddit.com/r/freelance/comments/1l1vhwi/i_filed_a_legal_claim_after_being_unpaid_for_work/

  Weakness: expensive/time-consuming after damage is done; user is "still in the middle of the claim process."

- Contracts before starting / Agree.com:
  > "Invoices & contracts: I use agree.com. It’s free and easy. I send a contract before starting, so expectations are clear from day one."  
  Source: https://www.indiehackers.com/post/saving-extra-1200-and60-hours-in-1-month-38e0e4fefe

  Weakness: free generic contract flow may not address working-file ownership, usage rights, milestone escrow, proof-of-use, or late payment enforcement.

- Fiverr Workspace / AND.CO:
  > "Fiverr Workspace (formerly AND.CO) is being discontinued on March 1, 2026."  
  Source: https://www.reddit.com/r/freelance/comments/1rh8naj/psa_fiverr_workspace_andco_shuts_down_march_1/

  Migration needs:
  > "Keep PDFs of key contracts + paid invoices" and "List recurring invoices, payment links, late-fee terms, templates you want to reuse"  
  Source: https://www.reddit.com/r/freelance/comments/1rh8naj/psa_fiverr_workspace_andco_shuts_down_march_1/

### Willingness-to-pay signals
- Freelancers are already losing significant unpaid invoice value (amount not disclosed) and spending time on reminders/legal claims.
- A creative professional escalated to small claims, proving willingness to spend time/money enforcing payment and IP boundaries.
- Fiverr Workspace users had centralized invoices/contracts/proposals/client info; discontinuation creates active migration demand.
- Indie Hackers post estimates workflow-switching at $1,200/month for a $20/hr freelancer, implying budget if a tool clearly recovers time or prevents nonpayment.

### Underserved angle / possible product direction
- Not generic invoicing. Better niche: **freelancer payment-protection + creative deliverables rights management**.
- Features: milestone deposit/escrow, contract clauses for working files vs final assets, proof-of-delivery timeline, auto reminders/late fees, public/private evidence vault, client approval log, migration importer from AND.CO/Fiverr Workspace, one-click small-claims packet.

---

## Runner-up observed but not in top 4: PEPPOL / e-invoicing compliance for EU microbusinesses

Fetched HN thread: https://news.ycombinator.com/item?id=42777669  
Visible HN engagement: **67 points, 76 comments**.

Reason not top 4: strong compliance pain and WTP, but more geography-specific (Belgium/Latvia/EU) and less directly tied to the target hunting-ground subreddits. Still worth watching.

Key quotes:
- > "All business-to-business invoices in Belgium will have to be sent over PEPPOL as of next year... Gone will be the days of emailing PDFs."  
- > "Direct access is nearly impossible (it is expensive and requires technical audits). A variety of third parties are popping up to mediate access. They all seem complex and expensive."  
- > "If you're a small business, this could get pretty complicated pretty quickly."  
- > "That's what the Belgian guideline seems to be, yeah. From what I gather, the extra costs are deductible at 120% during the first year. But it still all feels pretty shitty."  
- > "money is being pulled away from freelancers and small SME's for every invoice they send."  

WTP/pricing quotes from same HN thread:
- > "I pay about 120€/mo. for a solution that includes bookkeeping, electronic and traditional invoicing, electronic and traditional expenses management, salary/payroll and all tax declarations for my 1-person company."  
- > "someone could probably provide a \"proxy\" processor for something like 100€/year."  
- > "I’m using an intermediary saas platform that has a free plan. I don’t like being forced to use an external provider, just for being able to send invoices, but at least it’s not costing me any money (yet)."

---

## Evidence caveats

- Reddit pages were fetched and quoted from `web_extract`, but Reddit's current public page extraction did not return most comment bodies or reliable post/comment counts. I did not cite unfetched comments. Search-result snippets sometimes indicated comment counts or comment content, but I did not use those as primary evidence unless the URL itself was fetched and the quoted text appeared in the extracted page.
- Dates are inferred from fetched Reddit page chrome/top-post blocks and web_search descriptions; where exact post age looked inconsistent with subreddit date blocks, I preferred describing the year/thread batch rather than overclaiming exact age.
- No claims above rely on non-fetched URLs.
