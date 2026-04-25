# Humdrum: Adversarial Feature Debate — Synthesis & Surviving Roadmap
**Date:** April 25, 2026
**Inputs:** PM (`perspective_pm.md`), Principal Engineer (`perspective_engineer.md`), Senior Designer (`perspective_designer.md`), Privacy Skeptic (`perspective_privacy.md`)
**Output:** Prioritized surviving feature list for Phase 3 (technical feasibility) and Phase 4 (development plan)
**Constraint:** Strictly local, no exceptions. Mutter dictation surface first.

---

## 1. How the Voting Works

Each candidate feature was voted on by all four agents. A feature SURVIVES if it has at least 3/4 YES votes for v1 OR a clear consensus path to a later milestone (v1.1 / v2). A feature is KILLED if it has 3/4 NO/KILL votes, or if a single hard-veto (privacy violation that can't be designed around) lands.

Votes use this shorthand:
- **YES-v1** = ship in v1.0
- **YES-v1.1** = ship in first polish release after v1.0
- **YES-v2** = ship in second major release (meeting recorder era)
- **DEFER** = revisit with telemetry; not on the 12-month roadmap
- **KILL** = remove from roadmap entirely
- **VETO** = privacy hard-no that overrides other YES votes

---

## 2. Consensus Table — Mutter Candidates (M1–M15)

| ID | Feature | PM | Eng | Designer | Privacy | Verdict |
|---|---|---|---|---|---|---|
| M1 | Pre-warm model on launch/sleep | YES-v1 | YES-v1 (ship-now) | YES-v1 (low-pri) | CLEAN | **YES-v1** |
| M2 | Local punctuation + sentence-breaking | YES-v1.1 | YES-v2 (Q3) | YES-v1 (mandatory) | CLEAN | **YES-v1.1** (must-ship; biggest "why-cloud" demolisher) |
| M3 | Local rewrite mode | DEFER | DEFER | KILL-v1 | KILL-v1 (LLM download trap) | **DEFER to v2.5+** |
| M4 | App-context-aware formatting | YES-v1.1 | YES-v2 | YES-v1.1 | CLEAN | **YES-v1.1** (5 hardcoded apps, no UI for custom) |
| M5 | Custom vocab beyond 224 tokens | YES-v1.5 | YES-v1 (ship-now) | YES-v1 | GREY (no iCloud sync) | **YES-v1** (regex+rotated prompts, local only) |
| M6 | Transcription history with search | YES-v1.1 | YES-v1 (ship-now) | YES-v1 | CLEAN | **YES-v1** (menu-bar dropdown, last 20) |
| M7 | Multi-language toggle | YES-v1.1 | YES-v2 (Q2) | YES-v1 (manual only) | CLEAN | **YES-v1.1** (manual toggle; auto-detect deferred) |
| M8 | Power-user automation hooks | YES-v1 (URL+Shortcuts) | YES-v2 | YES-v1 (URL+Shortcuts) | GREY (document boundary) | **YES-v1** (URL scheme + Shortcuts; CLI/AppleScript v2) |
| M9 | Voice commands | KILL | DEFER | KILL-v1 | KILL-v1 | **KILL — feature trap** |
| M10 | Paste reliability hardening | YES-v1 (mandatory) | YES-v1 (ship-now) | YES-v1 (mandatory) | CLEAN | **YES-v1** (table-stakes; regression matrix) |
| M11 | Audit trail / proof-of-locality | YES-v1 announce / v1.5 deliver | DEFER (post-audit) | YES-v1 (messaging-heavy) | YES-v1 (Sigstore signed) | **YES-v1.5** (signed transcripts + network audit) |
| M12 | Graceful degradation UX | YES-v1 | YES-v1 (ship-now) | YES-v1 (mandatory) | CLEAN | **YES-v1** (state-color matrix) |
| M13 | Snippets / text expansion | DEFER | YES-v2 | KILL (out of scope) | CLEAN | **KILL — Keyboard Maestro/TextExpander territory** |
| M14 | iPhone as remote mic | KILL | DEFER | KILL | VETO (WiFi exposure) | **KILL for v1; revisit only with E2E + transparent comms** |
| M15 | Watch/iOS standalone | KILL | DEFER | KILL | VETO (iCloud sync risk) | **KILL — separate product line, post-v3** |

### Mutter survivors (in ship order)
1. **v1.0** (must ship): **M1, M5, M6, M8, M10, M12** + the existing app foundation
2. **v1.1** (first polish): **M2, M4, M7** (manual), **M11** (delivery)
3. **DEFER/KILL**: M3, M9, M13, M14, M15

---

## 3. Consensus Table — Meeting Recorder (R1–R11)

| ID | Feature | PM | Eng | Designer | Privacy | Verdict |
|---|---|---|---|---|---|---|
| R1 | System audio capture (ScreenCaptureKit) | YES-v2 | YES-v2 (Q2-Q3) | YES-v2 | CLEAN | **YES-v2.0** (table-stakes for meeting half) |
| R2 | Calendar-aware auto-record (EventKit) | YES-v2 | YES-v1 (ship-now) | YES-v2 (opt-in) | CLEAN | **YES-v2.0** (default OFF, explicit toggle) |
| R3 | Meeting-context Whisper hints | YES-v2 | YES-v1 (ship-now) | YES-v2.5 | CLEAN (local Contacts only) | **YES-v2.0** (auto from EventKit attendees + title) |
| R4 | On-device summaries (local LLM) | YES-v2.1 | YES-v3 (Phi-3.5; AFM Q4) | KILL-v1 (revisit) | VETO unless explicit download consent | **YES-v2.1 with explicit download flow** (Phi-3.5-mini gated; AFM opt-in upgrade on Sequoia+) |
| R5 | Action item extraction (LLM) | DEFER | DEFER | KILL | Same as R4 | **DEFER to v2.5+** (pattern matching first, LLM later) |
| R6 | Better diarization + user-assignable names | YES-v2 | YES-v2 (names first; ensemble later) | YES-v1.1 | CLEAN | **YES-v2.0** (user-assignable names; ensemble v2.5) |
| R7 | In-person meeting mode | DEFER | YES-v2.5 (basic only) | KILL-v1 | CLEAN | **YES-v2.5** (single-mic only; phone-mic deferred) |
| R8 | Cross-meeting search | YES-v2.1 | YES-v3 | YES-v2.5 | CLEAN (encrypted index) | **YES-v2.5** (keyword first; semantic later) |
| R9 | Local PII redaction | DEFER | YES-v2 (regex first) | KILL | CLEAN (local NER only) | **DEFER to v3** (regex-only minimum if shipped) |
| R10 | Per-meeting vocabulary auto-loading | DEFER | YES-v2 (after M5) | YES-v2.5 | CLEAN | **YES-v2.5** (after R2) |
| R11 | Recording as shareable artifact | YES-v2.2 | DEFER | YES-v2 | CLEAN (Sigstore signed) | **YES-v2.2** (signed `.humpack` zip) |

### Meeting Recorder survivors (in ship order)
1. **v2.0**: **R1, R2, R3, R6** (core meeting recorder)
2. **v2.1**: **R4** (with explicit consent download), **R11** (shareable artifact)
3. **v2.5+**: **R7** (in-person, basic), **R8** (cross-meeting search), **R10** (per-meeting vocab)
4. **DEFER**: R5, R9

---

## 4. Consensus Table — Cross-Cutting (C1–C4)

| ID | Item | PM | Eng | Designer | Privacy | Verdict |
|---|---|---|---|---|---|---|
| C1 | Trust narrative + audit + signed transcripts | YES-v1 | YES-v2 (parallel) | YES-v1 (mandatory) | CRITICAL OPPORTUNITY | **YES-v1.0** (announce); v1.5 (third-party audit + Sigstore) |
| C2 | Compliance posture (HIPAA/SOC2) | YES-v2 | YES-v2 docs | YES-v1.1 (docs) | YES-v2 (SOC2 Type I) | **YES-v1.1 docs; v2.0 audit** |
| C3 | Onboarding overhaul | YES-v1 | YES-v1 (ship-now) | YES-v1 (copy only) | CLEAN | **YES-v1.0** (improved copy + progress + per-step why) |
| C4 | Pricing & packaging | $49 lifetime + $4.99/mo recorder | Lifetime + free tier | One-time signals "crafted" | No "cloud tier" | **DECISION:** $49 one-time for Mutter; $39 add-on for meeting recorder; no subscriptions |

---

## 5. Consensus Table — Pivots (P1–P4)

| ID | Pivot | PM | Eng | Designer | Privacy | Verdict |
|---|---|---|---|---|---|---|
| P1 | Windows port | STRONG NO | SHIP-NEVER (6-10 mo, weak demand) | (implicit kill) | CLEAN if done right | **KILL** for v1-v3; revisit only if MRR justifies a separate Windows team |
| P2 | iOS standalone dictation | YES-v3 (long term) | DEFER (8-10 wk) | KILL | VETO if iCloud sync | **DEFER to v3+** as separate product |
| P3 | iPhone-as-Mac-mic | DEFER (in P2) | DEFER (4-5 wk after M14) | KILL | VETO (WiFi exposure) | **KILL for v1-v2** |
| P4 | Mobile in-person capture | YES-v3 | SHIP-NEVER | KILL | CLEAN | **DEFER indefinitely** (single-mic R7 covers most demand) |

---

## 6. Where the Agents Disagreed (and Who Won)

### a) M2 (local punctuation): "ship in v1" vs "v1.1"
Designer says **mandatory v1**. PM and Engineer say v1.1 because of the model-quality risk (an 85% punctuation model breaks trust faster than no model). **Resolution: v1.1.** A 4-week post-launch slot is acceptable if v1.0 ships with M10 (paste) + M12 (graceful degradation) + M6 (history) + M11 announcement bare-minimum.

### b) M11 (proof-of-locality): "v1" vs "after security audit"
Designer + Privacy say ship the messaging in v1. Engineer says don't ship signed transcripts until external security firm has reviewed the scheme. PM splits: announce v1, deliver v1.5. **Resolution:** v1.0 ships the transparency document (Wireshark steps, codesign verification, "what we send" disclosure) and a network audit script. Sigstore-signed transcripts ship in v1.5 after a $5–15k researcher audit.

### c) R4 (on-device summaries): "ship Phi-3.5" vs "kill"
Privacy will VETO any feature that silent-downloads a 2 GB model. Designer agrees. Engineer wants to ship in v3 with Apple Foundation Models. PM wants v2.1 with Phi-3.5. **Resolution:** v2.1 ships R4 with **explicit download consent flow** ("Enable summaries? This downloads a 1.6 GB on-device model — one-time"). Default OFF. Apple Foundation Models becomes a Sequoia+ opt-in upgrade in v2.5.

### d) M3 (rewrite mode): "DEFER" vs "kill"
PM/Eng say defer; Designer/Privacy say kill. **Resolution: DEFER.** The feature isn't structurally cloudy — it just shares the LLM-download problem with R4. Once R4's consent UX is built, M3 can ride on the same model and the same consent. Re-evaluate in v2.5.

### e) Windows port (P1): "Eventually" vs "Never"
PM says strong-no; Engineer says ship-never; Designer dismisses; Privacy says clean if done right. **Resolution: KILL** as a v1-v3 commitment. The bear-case is unanimous: WhisperKit is Apple-only, FluidAudio is Core ML, Mac power-user is the wedge, and weak demand from privacy users. Revisit only if a quarter shows Windows demand > 20% of inbound.

---

## 7. The Three Privacy Violations Already in the Binary

The Privacy reviewer flagged three issues that exist *today*. None are show-stoppers but all need disclosure or remediation in v1.0:

1. **Sparkle update calls** — Outbound HTTP to fetch the appcast. Acceptable but must be disclosed in About panel and quarterly transparency report. Move to a separate XPC agent in v1.5 so the main binary can be `network.client: false`.
2. **WhisperKit / FluidAudio first-run model downloads** — Hugging Face CDN. Document on first launch ("first model download is ~120 MB; happens once"). Provide an alternative bundled-model build for compliance customers.
3. **`com.apple.security.network.client` entitlement = true** — This single entitlement undermines the "network zero" claim. Plan: split Sparkle out, ship main binary with the entitlement removed in v1.5 (after audit firm signs off).

---

## 8. The Surviving Feature List (Ordered)

This is what Phase 3 (technical feasibility) and Phase 4 (development plan) operate on.

### v1.0 — "Mutter, polished" (target 4–6 weeks engineering)
- **M1** Pre-warm model on launch / sleep
- **M5** Custom vocabulary (regex substitution + rotated prompts; local only)
- **M6** Transcription history with menu-bar dropdown
- **M8** Power-user automation hooks (URL scheme + Shortcuts.app)
- **M10** Paste reliability hardening (regression matrix, top 20 apps)
- **M12** Graceful degradation UX (state-color matrix, error pills)
- **C1-α** Trust narrative announcement (transparency doc, Wireshark steps, About-window disclosure)
- **C3** Onboarding overhaul (per-step why, model-download progress)
- **C4-decision** Lock pricing ($49 lifetime for Mutter)
- **Existing fixes** (from `ADVERSARIAL_REVIEW.md`): Stop→Start lockout fix, paste hardening for Electron, @State leak resets

### v1.1 — "Polish + differentiation" (target 4–6 weeks after v1.0)
- **M2** Local punctuation + sentence-breaking pass (~150 MB distilled model)
- **M4** App-context formatting (5 hardcoded apps: Slack, Gmail, Notion, VS Code, Cursor; no custom-rule UI yet)
- **M7** Manual multi-language toggle (Settings dropdown; reload model on change)
- **C2** Compliance documentation (HIPAA-ready architecture doc; SOC2 path published)

### v1.5 — "Trust delivery" (target 4–6 weeks after v1.1)
- **M11** Sigstore-signed transcripts + audit trail
- **C1-β** Third-party security audit publication (Pragmatic Labs or independent researcher)
- **Quarterly transparency report #1**
- **Sparkle XPC isolation** (drop `network.client` from main binary)

### v2.0 — "Meeting recorder launch" (target ~3 months after v1.5)
- **R1** System audio capture (ScreenCaptureKit primary, CoreAudio Tap fallback)
- **R2** Calendar-aware auto-record (EventKit; default OFF, opt-in)
- **R3** Meeting-context Whisper hints (auto-fill from EventKit attendees + title)
- **R6** Better diarization + user-assignable speaker names

### v2.1 — "Local intelligence" (target ~6 weeks after v2.0)
- **R4** On-device summaries (Phi-3.5-mini, explicit consent download flow, default OFF)
- **R11** Shareable artifact (signed `.humpack` zip)
- **C2** SOC2 Type I attestation publication

### v2.5+ — "Power user expansion"
- **R7** In-person meeting mode (single-mic basic)
- **R8** Cross-meeting search (keyword first; semantic via local embeddings later)
- **R10** Per-meeting vocabulary auto-loading
- **AFM upgrade** (Apple Foundation Models on Sequoia+ as opt-in alt to Phi-3.5)

### DEFERRED / KILLED
- **DEFER (revisit with telemetry):** M3 (rewrite), R5 (action items), R9 (PII redaction)
- **KILL (off the roadmap):** M9 (voice commands), M13 (snippets), M14 (iPhone-as-mic), M15 (Watch/iOS), P1 (Windows), P2 (iOS standalone), P3 (iPhone-as-mic), P4 (mobile in-person)

---

## 9. Three Things The Adversarial Round Surfaced That The Original Research Missed

1. **The Sparkle entitlement is a credibility liability.** None of the Phase 1 research (which focused on competitor sentiment) flagged that Humdrum's own Info.plist contains `com.apple.security.network.client = true`. The Privacy agent's "two-tier entitlement" recommendation (XPC-isolate Sparkle so the main binary has zero network capability) is novel and uniquely defensible — no competitor has done this.

2. **App-context formatting (M4) and pre-warm (M1) interact.** Engineer flagged that pre-warming a `medium.en` model on an 8 GB M1 thrashes; if the user later downgrades to `tiny`, the pre-warm UX is wrong. C3 onboarding needs a smarter device-RAM check before defaulting model quality. This wasn't on any of the v1 lists pre-debate.

3. **The model-download problem is shared across M3, R4, R5, M9.** All four "intelligent rewriting/summarizing" features hinge on the same LLM-download UX. A single consent flow design, built once for R4, unlocks M3 and R5. Phase 3 (feasibility) must spec this consent flow first.

---

## 10. What Phase 3 Must Answer

For each surviving feature, Phase 3 needs to deliver:

- **The most robust local implementation path** (which API, which model, which fallback)
- **Specific RAM/CPU/disk budget** on baseline M1 8 GB
- **Failure modes and graceful-degradation behavior** (what happens when the API is missing or fails?)
- **macOS version-min impact** (does this push us off Sonoma?)
- **A concrete spike or proof-of-concept plan** if uncertainty is high

The features with the highest feasibility-research priority are:
1. **M2** (local punctuation model selection)
2. **M10** (per-app paste strategy matrix; this is engineering, not research, but the matrix needs to be specified)
3. **M11** (Sigstore signing scheme; cryptographic design)
4. **R1** (ScreenCaptureKit vs CoreAudio Tap; permission UX)
5. **R4** (Phi-3.5 vs MLX-Llama-1B vs Apple Foundation Models for summaries)
6. **C1** (audit firm shortlist + scoping)

Phase 3 begins now.
