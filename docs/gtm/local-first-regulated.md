
# MeetingPipe roadmap: ship local, sell to the regulated

You are building the only tool with a credible answer when a hospital CIO, a Big Law partner, or a Lockheed program manager asks "where does the audio go?" — and that question is being asked more loudly every quarter. Otter's class action (*In re Otter.AI Privacy Litigation*, motion-to-dismiss hearing May 20, 2026), Fireflies' BIPA suit (*Cruz v. Fireflies*, Dec 2025), Stanford / UW-Madison / Cornell / Chapman / Maryland state government IT bans on AI notetakers, NYC Bar Formal Opinion 2025-6 (Dec 22, 2025) explicitly targeting AI meeting tools, and the ABA GP Solo article (Sept 2025) literally recommending "deploy AI locally" — all of this is post-2024 evidence that the wedge is real and widening. The thesis below is built around that wedge, not around beating Granola at its own game.

---

## 1. Competitor landscape (May 2026)

**The category split that matters:** cloud-bot tools (Otter, Fireflies, Fathom, Read, tl;dv), cloud-no-bot tools (Granola, Bluedot, Tactiq, Jamie, MeetMemo), and **truly local** tools (MacWhisper, Krisp Enterprise, BB Recorder, Char, the GitHub clones, Limitless via Mac-side processing — now sunsetting). MeetingPipe lives in the third bucket and that bucket has six entrants as of May 2026, up from one in 2024.

### Cloud-bot incumbents

**Granola** — **HIGH threat.** $1.5B valuation (Series C, Mar 25, 2026, Index lead). $14/user/mo Business, $35+/mo Enterprise; dropped the $18 Individual tier early 2026. Audio capture is local but **transcription and AI processing are cloud**. **No HIPAA, no BAA** (confirmed on their own page). SOC 2 Type II July 2025. Default opt-in to AI training; org-wide opt-out gated to Enterprise. ~94 employees, ~15k enterprise customers, $400%+ YoY ARR claim. Recent: MCP server (Feb 2026), Spaces / Public API (Mar 2026), locked-down local DB caused a16z partner backlash. Granola owns the bot-free macOS mindshare and the consumer-VC aesthetic. Their unfilled hole is regulated compliance + true on-device. *Position against them on compliance, not on Mac-nativeness.*

**Otter** — **MEDIUM threat as substitute, HIGH as foil.** $100M ARR (March 2025), 35M+ users, HIPAA BAA on Enterprise only (since July 2025). $8.33–$30/user/mo. **Active class action** alleges covert recording + ECPA/CIPA/BIPA-style training violations; motion-to-dismiss May 20, 2026. Every regulated buyer has heard the story. Use Otter as the "what you're escaping" reference in marketing copy.

**Fireflies** — **MEDIUM.** $1B unicorn valuation via tender (June 2025), $10/user/mo Pro, cheapest CRM-deep option, HIPAA on Enterprise. **BIPA class action** *Cruz v. Fireflies* (Dec 2025). Bot-based, cloud-everything.

**Fathom** — **MEDIUM.** Free tier (5 AI summaries/mo cap is the squeeze). $15–29/user/mo paid. Bot-free beta in 2025. No new funding since 2022. Free tier is the real anti-MeetingPipe pricing problem, not Granola.

**Read.ai, tl;dv, Tactiq** — **LOW–MEDIUM each.** Read's auto-join behavior is destroying its brand (1.4/5 Trustpilot, banned at Chapman/UW/UC Riverside). tl;dv pivoted to sales coaching. Tactiq is Chrome-only, no audio.

### Privacy / local-first peers

**MacWhisper** — **HIGH threat.** Closest privacy peer. ~$69 lifetime (Gumroad) or $99.99 Mac App Store. **Shipped automatic meeting recording in 2025–26 beta** (detects Zoom/Teams/Webex/Slack/etc., records mic + system audio, diarizes locally, summarizes via local Ollama or chosen cloud LLM). This is the single most important competitive fact in this report. Jordi Bruin is the indie incumbent. Distribution dominance, low price, the same fundamental architecture as MeetingPipe.

**Krisp Enterprise** — **HIGH threat.** Only competitor that already ships **on-device transcription + HIPAA + no-training pledge**. $15/user/mo Advanced, custom Enterprise. Their note quality is weak but the positioning collision is real.

**Bluedot** — **HIGH threat.** Bot-free Mac meeting recorder, cloud-processed transcription. $14–20/seat/mo. Already serves ~50k companies. MeetingPipe wins the privacy axis; Bluedot wins on CRM depth and Salesforce/HubSpot integrations.

**The 2025–26 newcomer wave** — **HIGH cumulatively.** Jamie (Mac+Win, local ASR + EU-cloud summary), MeetMemo (Belgium, WhisperKit + EU Gemini), BB Recorder ("100% local, free, no account"), Char (BYO-AI open source), Hedy (real-time coaching), Slipbox AI, plus active GitHub builds (tonton-golio/meeting-recorder, pasrom). The privacy-first Mac niche went from empty to crowded in 18 months. **Differentiation is narrowing fast.**

**Superwhisper, AudioPen, Whisper Memos, Cleft** — adjacent (dictation / voice-thinker). LOW.

**Limitless / Rewind** — **acquired by Meta Dec 5, 2025**, new sales stopped, desktop app sunsetting. Threat = NONE.

**Plaud (Note / NotePin / Note Pro)** — **MEDIUM-HIGH** in the in-person + hardware market. Plaud Desktop now does online meetings. Cloud-only architecture is your wedge against them.

---

## 2. Niche analysis: the buyers who can't use Granola

**The TAM that matters is not "Mac users who hate bots." It is "US/EU regulated knowledge workers whose IT or bar association won't let them touch Otter/Granola/Fathom."**

### Consultants under NDA

Combined Big Four headcount is ~1.6M (Deloitte 460k, EY 400k, PwC 370k, KPMG 273k); add 300k–1M independent US consultants (Catalant / Umbrex / Upwork tier). Software stack spend: $1,200–$5,000/year. Granola is the *de facto* tool in VC/consulting Twitter — and Granola has no HIPAA and defaults users into AI training on the lower tiers. **Multi-employer / outsource consultants are explicitly the buyer who needs per-client routing** — your Workflows model maps 1:1 to their pain (Client A = local LLM under NDA → Notion DB A; Client B = cloud LLM allowed → Notion DB B).

### Regulated knowledge workers

- **Lawyers**: 1.37M US active resident lawyers (ABA, 2025). **NYC Bar Formal Opinion 2025-6** (Dec 22, 2025) holds that secret AI recording violates Rule 8.4 *even in one-party-consent states*. ABA Formal Opinion 512 (July 2024), Florida 24-1, California guidance, Texas Op 705, NC FEO 1, PA mandatory disclosure rule. ABA GP Solo (Sept 2025): *"deploy AI locally or within secure firm infrastructure."* Practical-management tools like Clio sell at $59–$129/user/mo. Lawyers pay.
- **Clinicians**: 839k US physicians, 3.4M RNs, 383k APRNs (BLS, 2024). ~30% of practices already use AI scribes. Emory Health deployed Mac for Epic Hyperspace at scale in 2024; UMC Utrecht: 85% of clinicians pick Mac. **Granola explicitly does not offer HIPAA** — this is the open lane.
- **Life sciences**: US 2.1M (CBRE, Q2 2025), EU ~750k. **FDA 21 CFR Part 11**: no mainstream meeting AI vendor advertises Part 11 validation. White space.
- **Finance**: **FINRA Regulatory Notice 25-07** explicitly opened comment on AI transcripts and recordkeeping. $2B+ in SEC off-channel-communications fines since 2021. Compliance officers ban anything that creates unsupervised records.
- **Federal / defense**: Maryland DoIT, only **Gemini and Copilot (FedRAMP High)** are approved. **No meeting-AI vendor has FedRAMP authorization** as of Q1 2026. ITAR/CUI categorically excludes commercial cloud transcription.

Explicit institutional bans on Otter, Fireflies, Read, Fathom, Sembly, Grain, Avoma, MeetGeek, etc., are documented at **Stanford, UW-Madison, UIUC, Cornell, UC Riverside, Chapman, Tufts, University of Washington, State of Maryland**. The pattern is accelerating, not stable.

### Privacy nerds (r/LocalLLaMA, r/selfhosted)

~700k members each. They buy in low volume but they evangelize. Useful as launch amplifiers, not as a primary revenue niche. **Do not optimize the product for this group; they will use the OSS CLI.**

### Documented incidents driving the demand

Feb 2022 Politico/Otter–Uyghur incident; Sept 2024 Alex Bilzerian VC-deal-killed-by-Otter-transcript-email; **Brewer v. Otter.ai (consolidated as In re Otter.AI Privacy Litigation)**, motion-to-dismiss May 20, 2026; **Cruz v. Fireflies (BIPA)**, Dec 2025; Granola exposed-API-key incident exposing 333 beta transcripts. Each is a marketing artifact. Quote them in landing pages.

**Estimated SAM:** ~6–8M US regulated knowledge workers + 1M+ NDA-bound consultants × ~15–25% Mac share (rising fast in healthcare and legal) × ~30% currently using a meeting tool daily ≈ **600k–1.2M real US buyers**, plus EU/UK comparable. At $99 lifetime that is a $60–120M reachable TAM; you need 500–2000 paying customers in year one, which is 0.05–0.2% of SAM. **Reachable.**

---

## 3. Positioning against platform and incumbent threats

**Apple does not kill MeetingPipe.** iOS 18.1's call recording and macOS 26 Tahoe's Phone-app recording are **locked to Apple's Phone and FaceTime audio only**. There is no public API and no announced product that records system audio from Zoom, Teams, or Meet on macOS with a built-in Apple Intelligence summary. Private Cloud Compute is genuinely best-in-class on the privacy axis (cryptographic attestation, no retention, no training), but it never enters this product's data path because Apple does not record Zoom/Teams/Meet. Watch macOS 27 closely — Apple's investment direction (Notes voice memos, Live Translation, Call Screening) suggests this gap closes by 2027–2028. **You have a 12–24 month window of platform-level absence.**

**Microsoft Copilot for Microsoft 365 + Teams Intelligent Recap** is **Teams-only**. $30/user/mo enterprise add-on, $18 SMB. 15M paid seats out of 450M M365 commercial subscribers (~3.3% conversion); activation rate among licensed users 35.8%. Outside Teams, Copilot is irrelevant for meeting capture. **Threat = MEDIUM only for Teams-monoculture orgs**, which by definition aren't the multi-platform consultant buyer.

**Zoom AI Companion 3.0** and **Google Meet "Take Notes for Me"** **both went cross-platform in late 2025 / April 2026** — Zoom's "My Notes" captures Teams + Meet + in-person notes; Google's Take Notes for Me extended to Teams + Zoom at Cloud Next 2026 (April). **This is the most important competitive shift of the last 18 months** and the report deck Granola sent its Series C investors is already obsolete. **The "I use three meeting platforms in a day" wedge has narrowed.** The wedge that survives is regulated buyers who can't use any cloud-summarization tool, period — and bot-averse hosts whose participants kick the bot.

**Granola's "audio never leaves" claim is increasingly a marketing nicety in 2026.** Audio capture is local on Granola; transcription and AI processing go to cloud. Their own privacy page is technically accurate but obfuscates that transcript text and metadata leave the device. **True local-first processing is now the only defensible privacy moat**, and Krisp Enterprise + Jamie + MeetMemo + BB Recorder are all crowding into it. **Defensibility comes from compliance documentation and regulated-buyer trust, not from architecture alone.**

---

## 4. Growth potential

**TAM math.** Apple active devices 2.5B (Q1 2026); estimated active Mac install base ~100M. US/EU regulated + NDA-bound knowledge workers ~10M; Mac share in this group ~15–25% and rising (Emory/UMC Utrecht evidence); ~30% use meeting tools daily. **Realistic reachable SAM: 500k–1.5M individuals.**

**12-month trajectory (solo OSS-then-commercial).** Reference: MacWhisper has converted a Mac-only Whisper wrapper into a six-figure-ARR business via Gumroad over ~3 years; no confirmed 2026 ARR tweet but indie convention is that strong launches in this niche convert at 1–3% from HN-front-page traffic. A realistic plan: 200–600 paid licenses in Q3/Q4 2026 (post-launch), 1,000–2,500 by end-Q1 2027 if compliance positioning lands two or three legal/medical referral chains. **Revenue at $129 one-time × 1,500 = ~$190k year one** (gross before MoR fees). That is the right ambition; do not model it as a $1M+ year.

**Word-of-mouth dynamics.** Legal-tech adoption is mostly listicle-driven (ABA TechReport, Lawyerist, Above the Law) plus state-bar tech section recommendations. Medical software spreads at the practice level (one EHR/scribe champion converts a 10-doc practice). Consulting spreads via Twitter/LinkedIn endorsements from VCs and partners. **None of these segments responds to paid acquisition.** All three respond to compliance content and named-client case studies. **Two regulated case studies — one law firm and one clinical practice — outperform $20k of Google Ads.**

---

## 5. Pricing model — recommendation

**Recommended: $129 one-time license, per-machine, with optional $29/year for major-version updates after year one. Team pack of 5 seats at $499 ($99.80/seat). Source code MIT for the CLI and engine; closed-source for the macOS app (signed/notarized binary). No subscription.**

### Why this and not the alternatives

| Model | Why rejected |
|---|---|
| Pure OSS | Cannot sustain a solo developer at this product complexity. Regulated buyers prefer a paid vendor who can sign a BAA/DPA; OSS-with-no-vendor is a procurement non-starter. Plausible's OSS model works because their commercial side is cloud-hosted SaaS — you have no comparable cloud side and shouldn't build one. |
| Pure closed-source SaaS | Defeats the privacy thesis. Buyers cannot audit, regulators cannot validate, and the entire moat ("audio never leaves your Mac") becomes a trust-me claim. |
| Subscription only ($9–15/mo) | Indie Mac community treats subscription as cultural negative (Ulysses, Bear backlash); regulated personal buyers face audit friction on recurring SaaS; **CleanShot X, MacWhisper, Things, Soulver all hold the line at one-time + optional renewal**. Recurring is what the buyer is trying to escape from Otter/Granola. |
| Lifetime $59 (MacWhisper price) | Leaves money on the table for a more compliance-positioned product. MacWhisper is a transcription utility; MeetingPipe is a compliance-grade meeting tool. **Price slightly above MacWhisper signals seriousness.** |

### Specific figures

- **Solo $129 one-time**, includes 12 months of updates.
- **Annual update license $29/year** thereafter (CleanShot X model). User keeps using the version they bought even if they don't renew; only loses new features.
- **Team Pack: 5 seats / $499 one-time / $99/year update** for 5 seats. **10-seat / $899.** **25-seat / $1,999.** Centralized license server (license keys, not phone-home).
- **Education/journalism/nonprofit 30% off** (MacWhisper / Things precedent).
- **No HIPAA BAA on solo tier.** **BAA only on Team Pack 5+** ($499). This makes BAA legal exposure tractable.
- **CLI / engine open source under MIT.** macOS app closed-source, signed, notarized. This gives you the OSS halo on HN, lets compliance-paranoid buyers audit the actual data-flow code, and preserves commercial viability of the polished surface.

### Billing

**Paddle as Merchant of Record.** Only mainstream MoR with explicit Ukrainian seller support (Paddle blog, Feb 2022 — confirmed). Handles EU VAT, US sales tax, GST, reverse-charge for EU B2B. Fee ~5% + $0.50 + FX. Lemon Squeezy is being progressively folded into Stripe Managed Payments and Ukraine support is PayPal-only — **do not start there in May 2026**. Stripe Atlas and Stripe Connect exclude Ukraine. Polar excellent for OSS-adjacent but Stripe-Connect-dependent; same Ukraine limitation. FastSpring overpriced. **Pick: Paddle.** If you can incorporate via Estonian e-Residency OÜ within 60 days, Stripe + Polar become available — file that as a separate workstream.

### Trade-offs

- Forfeits ARR multiples that VCs reward (subscriptions price 3–8× higher in acquisition math). You are not raising. Doesn't matter.
- Forfeits the cheap-monthly customer who would churn anyway. Acceptable.
- $129 may price you above the impulse-buy threshold for the privacy-nerd r/LocalLLaMA crowd. They aren't your highest-LTV customer. Education discount catches the ones who care.
- One-time licensing means you must keep shipping value to justify the $29 renewal. **This is a feature, not a bug** — it disciplines the roadmap.

---

## 6. Marketing strategy — launch sequence

**Recommended single sequence:** Launch the week of **Tuesday June 9, 2026** *provided WWDC does not overlap* — Apple's WWDC 2026 is widely expected the week of June 8; **verify the keynote date and, if conflict, lock Tuesday June 23, 2026** as the launch.

### Pre-launch (May 12 – June 1)

1. Ship the four driver blog posts in this order on `meetingpipe.app/blog`:
   - *How we transcribe Zoom audio without a bot on macOS* — ScreenCaptureKit + AVCaptureSession deep dive
   - *Whisper-large-v3 vs Parakeet vs WhisperKit on Apple Silicon: 2026 benchmarks*
   - *What HIPAA actually requires from a meeting recorder (and what Otter doesn't tell you)*
   - *Diarization on-device: sherpa-onnx vs pyannote on M-series Macs*
2. Recruit 20 beta users with at least 3 each from law, healthcare, federal/consulting. Get 5 ready to comment on launch day.
3. Ship the compliance pages (Section 7) and the 90-second demo video.

### Launch day (Tue June 9 or June 23, 2026)

| Time PT | Action |
|---|---|
| 12:01 AM | Product Hunt goes live. Hunt yourself. Founder maker comment within 5 min. |
| 8:00 AM | **Hacker News Show HN**. Title: `Show HN: MeetingPipe – Local, on-device meeting recorder for macOS (open source CLI)`. Link to the product page, not an email-gated landing. |
| 11:00 AM ET | r/macapps crosspost with `Self Promotion` flair, different title from HN. |
| 1:00 PM ET | r/LocalLLaMA crosspost — lead with the benchmark post, not the product. |
| Afternoon | r/sideproject, r/selfhosted. **Skip r/privacy, r/medicine, r/consulting, r/Lawyertalk** — they ban self-promo or auto-remove vendor posts. |

### T+1 to T+14

- T+1: Submit the HIPAA cornerstone post as a regular (non-Show) HN submission.
- T+3: r/legaltech and r/healthIT, leading with architecture write-up not the product.
- T+7: IndieHackers "lessons from launching" post.
- T+14: If Show HN landed 30–80 points, email `hn@ycombinator.com` for the second-chance pool with a substantive update.

### What success looks like

- Show HN ≥ 250 points / front page 6+ hours
- r/macapps top-of-week
- 5,000–15,000 site visits launch week
- 50–150 paying customers (1–3% conversion)
- Two regulated-buyer pilot conversations from compliance content
- ProductHunt: badge + backlink only. **Do not optimize for #1 PoD** — the 2025–26 PH data shows even top devtool launches convert at 1–3% of visitors with poor retention.

### Anti-patterns to skip

**No paid acquisition.** All replicable indie data (Uploadcare, T.LY, IndieHackers consensus) shows CAC > LTV/3 for dev tools under $20/mo. The one exception is Google Search Ads on exact competitor names ("otter ai alternative") capped at $200/mo — defer to Q4 2026 at earliest. **No bot-rings / no friend upvote rings**; HN detects and penalizes. **No agency-polished video**; founder-narrated screen capture outperforms.

---

## 7. Branding strategy

### Keep the name "MeetingPipe"

The subagent recommended a rename to "Conduit." **I disagree.** Here's why:

The premium-single-word pattern (Granola, Otter, Linear, Things) is occupied; trying to compete on premium-feel against a $1.5B unicorn means losing on the axis you can't win. The Unix-utility name pattern (`ripgrep`, `whisper.cpp`, `MacWhisper`, `Tailscale`, `OrbStack`) is exactly the aesthetic of the buyer who is going to evaluate this tool: a senior consultant who hates bots, a tech-savvy lawyer, a biotech IT director with a developer-tools subscription budget. **"MeetingPipe" reads as a Unix tool that takes meetings as input and produces notes as output.** That is exactly correct. The Granola buyer is not your buyer. Don't dress for the wrong wedding.

**Trade-off accepted:** This name will not pass the "would an enterprise CIO buy a tool with this name" test. You are not selling to enterprise CIOs in year one. If/when you do, that conversation involves a 6-figure contract and a security review, and the name is the smallest variable.

### Trademark, domains, namespace — actions

Trademark clear at first pass on USPTO and EUIPO; **commission a $300–$700 clearance opinion** (Gerben IP or similar) before filing because adjacent marks Formpipe (Sweden, Class 9/42) and Pipe Services SRL exist. File Class 9 (downloadable software) and Class 42 (SaaS).

**Acquire immediately**: `meetingpipe.app` (primary, HSTS-preloaded), `meetingpipe.com`, `meetingpipe.ai`, `meetingpipe.dev`. ~$80/yr total. **Claim today** before anyone notices: `@meetingpipe` on X, `meetingpipe` org on GitHub/npm/PyPI, Mac App Store reservation. The collision worth knowing: `github.com/humanophilic/MeetingPipe` is an unrelated academic project — harmless but means use a personal namespace on the org repo.

### Tagline

> **Meeting notes that never leave your Mac.**

Seven words, sentence case, declarative, quiet about AI, inverts Granola's productivity framing into data-locality framing. Use as h1 on the landing page and nowhere else (don't repeat in app UI).

### Positioning statement

> **MeetingPipe is a Mac-native meeting recorder and notepad for consultants, lawyers, and clinicians who can't put their conversations on someone else's server.**

### Commercial-grade compliance posture (ship before launch)

Total cost under $500 plus one weekend. Do **not** start SOC 2 (Vanta/Drata at $20k–$40k year-one would destroy unit economics below $200k ARR). Ship instead:

1. `/SECURITY.md` in the repo + `/.well-known/security.txt` (RFC 9116)
2. `/privacy` — explicitly state audio and transcripts never leave the device
3. `/terms` — base on Common Paper free templates
4. `/dpa` — Common Paper DPA, downloadable PDF, signable via DocuSign
5. `/baa` — HHS sample BAA, available only on Team Pack tier
6. `/security` — single page doing the work of a Trust Center: architecture summary, sub-processor list, code-signing/notarization, compliance posture stated honestly
7. `/subprocessors` — list every vendor that touches metadata
8. Pre-filled HECVAT-Lite and CAIQ-Lite PDFs ready to send when requested
9. Reproducible build instructions in the repo for buyers who want to verify the closed-source binary corresponds to the open-source engine

Defer SOC 2, ISO 27001, HITRUST, hosted Trust Center until a real $15k+ contract demands them. When that day comes, use Comp AI (`trycomp.ai`) or Delve (`delve.co`) at $2k–$7k year one rather than Vanta.

---

## 8. Pushback on the Product Direction brief

### 8a. The no-personal-voice-memos position — **keep it**

MacWhisper tried to be both a meeting recorder and a transcription utility and the two SKUs (Gumroad + App Store) confuse buyers. AudioPen and Cleft are clean voice-memo products; their meeting features are afterthoughts. Bundling dilutes the meeting product's compliance positioning ("local-first for privileged meetings") with a voice-memo workflow that competes against AudioPen on completely different axes (writing-style transfer, prompt-based rewrite, mobile-first). **The single recommendation: stay disciplined.** Voice memos can be a separate Good Snooze–style sibling app in 2027 if MeetingPipe lands. Bundling them now costs you compliance credibility for a feature most buyers won't use.

### 8b. The Workflow-context model — **ship it, but hide it**

Per-context configs work in tools where ~10% of users adopt them (Alfred workflows, Raycast extensions, Hammerspoon configs, BetterTouchTool gestures); they're loved by power users and ignored by everyone else. The Workflows model is correct for the multi-employer consultant — that buyer's pain is *exactly* "Client A NDA, Client B no-NDA, route accordingly" and no other tool solves it. **But for the median lawyer/clinician/finance buyer, Workflows is overhead.**

The single recommendation: **ship the Workflows engine but expose a single default "Personal" workflow at first run.** Hide the multi-workflow UI behind a "Add Workflow" button on the Workflows tab. New users see one config; power users discover the depth. This mirrors how Raycast hides extension complexity behind the default UI. Adoption rate of multi-config will be 10–15% — design for that.

### 8c. Pricing/licensing for regulated buyers — **they pay individually**

The evidence is unambiguous. Lawyers buy Clio at $59–$129/user/mo personally. MacWhisper sells $69 lifetime to ~five-figure customers. Clinicians buy Heidi Health, Abridge, and Suki personally before their hospital procures. **The regulated-industry individual buyer absolutely pays for indie tools, and the $99–$249 one-time price point sits comfortably under the $100 expense-receipt threshold most firms use.**

The "OSS + company-paid support" model is wrong for this category. Hospital IT, law firm IT, and biotech QA do not buy from solo OSS vendors via support contracts; they buy from named SaaS vendors with SOC 2 + BAA + Trust Center, or they let individuals expense indie tools below $100/yr. **You are aiming at the second path.** The first path requires hiring an enterprise AE in 2027 if/when traction warrants. Until then: solo $129 one-time, Team Pack $499, and BAA on Team Pack.

---

## 9. Roadmap (Q2 2026 – Q1 2027)

The constraint is solo + finite hours, target 500–2000 paying users in 12 months. The brief proposes Library UI as the Q2 priority. **I disagree on ordering.** Library UI is necessary but it does not produce a paying customer. Compliance documentation, payment infrastructure, and launch readiness produce paying customers. **Library UI ships in Q2 but is the medium item, not the big bet.**

### Q2 2026 (May–Jul) — **Big bet: ship launchable v1.0, monetize Day 1**

**Big bet:** All-of: payments live (Paddle MoR), Library UI shipped, four driver blog posts published, full compliance pages live, launch executed week of June 9/23. **Launch is the bet, not a deliverable of a future quarter.**

**Mediums (3):**
- Library main window with the three-pane layout per Product Direction (left rail / chronological list / Summary–Transcript–Audio–Corrections–Raw tabs)
- Onboarding flow (permissions walkthrough — ScreenCaptureKit, microphone, accessibility) and a 5-screen first-run
- Workflows UX: ship engine + single-default UX (per Section 8b)

**Maintenance:** Apple notarization pipeline; auto-update via Sparkle; crash reporting via locally-aggregated Sentry-compatible client (no cloud reporter — must match the privacy claim).

**User-visible milestones:** v1.0 GA shipped, library window, in-app license activation, onboarding.

**Revenue milestone:** **50 paying customers, ~$6,500 gross.**

**NOT doing this quarter, even though tempting:** streaming summarization (the 10–30s post-meeting latency is fine, perfect is the enemy of done); local LoRA training (correction records are accumulating fine for later use); calendar correlation (premature without traction signal); Windows version (never).

### Q3 2026 (Aug–Oct) — **Big bet: regulated-buyer beachhead**

**Big bet:** Land **two named regulated case studies** — one small law firm (2–10 attorneys), one clinical practice (5–25 clinicians). Convert each into a written case study and a 5-minute video. These are your highest-converting marketing assets for the next 24 months.

**Mediums:**
- Team Pack 5/10/25 (license server, centralized billing, BAA on request)
- Compliance content expansion: write the FINRA / 17a-4 cornerstone, the ITAR/CUI cornerstone, and the FDA 21 CFR Part 11 cornerstone
- Workflows UX maturity: per-workflow Notion DB routing UI, per-workflow LLM backend toggle, NDA-aware mode (forces local LLM if "NDA" flag set on workflow)

**Maintenance:** Bug bash from launch feedback; macOS 27 dev beta compatibility (WWDC 2026 announcement); Whisper / Parakeet model updates; sherpa-onnx upgrades.

**User-visible milestones:** Team Pack purchasable, two case-study pages live, Workflows v2 UI.

**Revenue milestone:** **400 paying customers cumulative, ~$50k gross.**

**NOT doing this quarter, even though tempting:** mobile app (separate product, never); calendar integration (defer to Q4 only if a paying customer asks twice); cross-recording analytics (violates positioning); team-shared dashboards (you have no team product); Zapier (use Notion as the integration layer).

### Q3 → Q4 go/no-go gate

**End of Q3 2026: if cumulative paid customers < 300 OR Team Pack sales < 10 OR no regulated case study landed, kill the commercial license track and convert to pure OSS + Patreon/GitHub Sponsors.** Donate the architecture, build a smaller product if the market signal is absent, and pursue MeetingPipe as a portfolio piece rather than a business. **Define this trigger now, in writing, in the README. Hold yourself to it.**

### Q4 2026 (Nov 2026 – Jan 2027) — **Big bet: streaming summarization**

**Big bet:** **Streaming summarization** (rolling summary updated during meeting, not just post-meeting). Reasoning: ABA / NYC Bar guidance suggests lawyers want to *see what's being captured* in privileged calls; clinicians want mid-meeting recap; consultants want decision tracking. Streaming summarization is the single most differentiating technical feature you can ship that none of MacWhisper, Granola Personal API, Krisp Enterprise, or Bluedot has shipped cleanly. **Local LoRA training is the alternative big bet** — defer it to Q2 2027. You have one technical bet's worth of solo hours per quarter; pick streaming.

**Mediums:**
- Localized UI (Ukrainian first because you can, then German + French — the EU compliance audience)
- Direct-to-CRM publishers (HubSpot first, Salesforce later — consultant-driven request)
- Black Friday / Year-end promo: 25% off Team Pack (Jordi Bruin's playbook)

**Maintenance:** Update Claude Sonnet 4.6 model integration to whatever ships in Q4; benchmark MLX local models against each other quarterly.

**User-visible milestones:** Streaming summary panel in the floating HUD; Ukrainian + German UI.

**Revenue milestone:** **900 paying customers cumulative, ~$110k gross.**

**NOT doing this quarter, even though tempting:** Apple Vision Pro support (no audience); Apple Intelligence integration via ChatGPT extension (architectural mismatch); LoRA / on-device fine-tuning (Q2 2027 bet); generic CRM via Zapier (drift).

### Q1 2027 (Feb–Apr) — **Big bet: enterprise-readiness pilot OR walk away decision**

**Big bet:** Either land one **5-figure ARR enterprise contract** (small law firm or hospital practice group buying 25–50 seats with a real procurement process) **or** decide to remain a single-customer-per-license indie. **Do not commit to enterprise without a real contract on the table.** SOC 2 work begins only if you have a signed letter of intent.

**Mediums:**
- HECVAT-Full and CAIQ-Full PDFs prepared (still self-attested, not audited)
- Vendor security questionnaire response library (you will have answered the same questions 50 times by then; templatize)
- macOS 27 / Apple Intelligence integration (only ChatGPT extension hooks, no Apple-cloud audio)

**Maintenance:** Year-2 update license renewals begin shipping (the $29 update fee on the original Q2 2026 cohort comes due — this is your renewals motion).

**User-visible milestones:** Public Trust page upgrade; whatever the Apple Intelligence integration looks like in macOS 27.

**Revenue milestone:** **1,500 paying customers cumulative, ~$180–220k gross including renewals.**

**NOT doing this quarter, even though tempting:** raising a seed round (you don't need it, and VCs will push the product toward Granola's positioning which is wrong for you); hiring (you don't need it); building a web app (defeats positioning); building voice memos as a "MeetingPipe Voice" add-on (separate app, separate brand, separate quarter — 2027 if at all).

---

## Executive summary

MeetingPipe ships into a privacy-first macOS meeting-recorder niche that went from empty to crowded between 2024 and mid-2026 (MacWhisper added auto-meeting recording, Krisp Enterprise added on-device transcription with HIPAA, Bluedot, Jamie, MeetMemo, BB Recorder, Char, and Hedy all entered), while the bundled-platform AI threats from Zoom My Notes and Google Take Notes for Me went cross-platform in late 2025 / April 2026 and narrowed the multi-platform wedge — but the regulated-industry compliance wedge widened materially with the *In re Otter.AI Privacy Litigation* class action (May 20, 2026 motion to dismiss), the Fireflies BIPA suit, NYC Bar Formal Opinion 2025-6 on AI notetakers, ABA GP Solo's September 2025 "deploy AI locally" recommendation, FINRA Notice 25-07, and explicit IT bans at Stanford, UW-Madison, Cornell, Chapman, UC Riverside, and the State of Maryland; the strategy is therefore to keep the name MeetingPipe (Unix-utility positioning, not premium-consumer), sell at $129 one-time + $29/yr updates and Team Pack $499/5 seats through Paddle as MoR (the only major MoR with Ukrainian seller support), open-source the CLI/engine while closing the macOS app, ship the minimum-viable compliance posture (SECURITY.md, security.txt, Privacy, Terms, DPA, BAA template, /security page) without paying for SOC 2 until $200k ARR forces it, launch on Tuesday June 9 or June 23, 2026 (WWDC contingent) with a Show HN + r/macapps + r/LocalLLaMA blast plus four pre-published driver posts on ScreenCaptureKit, Whisper/Parakeet benchmarks, HIPAA architecture, and sherpa-onnx diarization, and execute a quarterly roadmap whose big bets are launchable v1.0 in Q2, two named regulated case studies in Q3 (with a hard go/no-go kill-the-commercial-track gate at end of Q3 if < 300 paying customers), streaming summarization in Q4, and a single 5-figure enterprise contract or a walk-away decision in Q1 2027 — targeting 1,500 cumulative paying customers and ~$180–220k gross by April 2027.