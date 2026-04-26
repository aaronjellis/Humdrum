# Manual Test Matrix

Before every public release, walk through this matrix and confirm each cell.
The automated unit tests (`swift test` — Tier 1 pure logic in `HumdrumCore`)
cover bundle-ID routing, UTF-16 chunking, the transcript-delta diff, and
Whisper noise-filter thresholds. This document is the only thing that
catches the "AX silently no-ops" class of bugs where the code returns
success but nothing lands in the target app.

Run `swift test` before starting the manual pass — if anything there is
red, fix it first; the manual matrix is not going to surface pure-logic
regressions and the cells will lie to you.

## Setup

Before starting, make sure of the following: the build under test is the one you signed and notarized — not a dev build (dev builds sometimes lose their TCC grant), Accessibility permission is granted for the app, microphone permission is granted, and Mutter is set to its default quality (Balanced) so the test conditions match what most users will experience.

Test phrases live in the "Canonical phrases" section below — use those exact phrases so behavior is comparable across runs.

## Meeting recorder matrix

Record a 30-second sample, read the long paragraph, stop. Confirm the transcript is approximately correct (Whisper won't be perfect on every word — look for obvious dropouts, silent stretches, or runaway hallucinations rather than word-level perfection).

| Scenario | Pass criteria | Last checked | Notes |
|---|---|---|---|
| Default mic, Balanced quality, normal filter | Transcript reads back recognizably | | |
| External USB mic selected in Settings | Same | | |
| AirPods / Bluetooth input | Same; no dropouts mid-sentence | | |
| Speaker labels ON, two voices | Two distinct "Speaker 1" / "Speaker 2" sections | | |
| Best quality model (medium.en) | Longer warmup acceptable; transcript cleaner | | |
| Auto-save folder set | File appears in folder immediately after stop | | |
| Stop during "Finalizing…" | No crash, transcript still saves | | |
| Start a second recording right after stopping | No multi-minute stall; second recording starts clean | | |

## Mutter dictation v2 (utterance-paced commits, keep listening)

This is the canonical Mutter matrix as of the paste-pivot. Pastes now fire at human-utterance cadence: each `silenceTimeoutSeconds` of silence triggers one ⌘V of *the new tail* of the transcript (the diff against everything previously pasted), and the engine stays running so the user can keep talking into the same orb without re-arming with ⌥Space. Stay silent through both the ring-drain (phase 1) and the orb scale-down (phase 2) and the session ends, with any unflushed tail-pass text pasted at teardown. The bug this design fixes: long sentences used to paste as nothing because per-Whisper-commit pasteboard restores raced with Electron's lazy clipboard reads — utterance-paced commits give each clipboard restore time to resolve before the next paste arrives. See `mutter-paste-research.md` and `mutter-paste-pivot-plan.md` for the receipts.

### What to verify on each cell

For each target app: focus a text field, press ⌥Space, read the test phrase aloud, wait for silence-timeout, then check:

1. **Orb has constant breathing motion.** Even before you speak, the orb should subtly pulse + drift in 2D — that's the always-on "engine is running" signal. The motion is small (~3% scale, ±1 pt drift) but visible peripherally. If the orb sits perfectly still, the timeline-driven aberration helpers are broken.
2. **"Listening…" indicator only while you're speaking.** The dots should fade in within one frame of you starting to talk and fade out within ~300 ms once you go quiet. They should NOT be visible during pre-speech silence or thinking pauses — only while audio is actively detected. The orb's breathing covers the "is it on?" question; the dots cover "is it hearing me?"
3. **Paste lands at end of phase 1; engine keeps listening through phase 2.** Stop talking. The countdown ring drains over your configured `silenceTimeoutSeconds` (phase 1). The moment it reaches zero, the new tail of the transcript should appear in your focused field as a single ⌘V. The orb should *then* begin scaling down 1.0 → 0 over another `silenceTimeoutSeconds` (phase 2) — but the engine is still hot. Start talking again during the fade and the orb should snap back to full size, the ring should re-arm, and the next phase-1 boundary should paste only the *new* tail (no double-paste of what already landed). Stay silent through the full 2T window and the orb disappears for good — any text the live stream hadn't surfaced yet flushes via the `stop()` snapshot pass at that moment, so you should never lose a tail. Hotkey-stop also flushes the diff before tearing down, so a quick ⌥Space after a fast utterance shouldn't lose the final words.
4. **No StatusPill in the happy path.** The pill should only appear if Accessibility is missing, the cascade refused, or AX detected a silent drop.
5. **`.silentDrop` pill on Electron silent-drop targets.** Where the receiving app eats the ⌘V (some Electron / hardened web views), the pill should appear with copy "That app didn't take the paste — ⌘V to insert" and the dictation text should still be on the clipboard for at least 3.5 seconds afterwards.
6. **Clipboard preservation.** The user's prior clipboard contents should be restored ~3 seconds after a successful paste; in the failure path, the dictation text should remain on the clipboard so the manual ⌘V works.

### Critical apps (regression risk)

| App | Short phrase | Long paragraph (>30s) | Tricky chars | Listening dots? | Pill state | Last checked |
|---|---|---|---|---|---|---|
| TextEdit | | | | | | |
| Notes | | | | | | |
| Mail compose | | | | | | |
| Safari (Gmail) | | | | | | |
| Chrome address bar | | | | | | |
| Slack composer | | | | | | |
| Claude desktop | | | | | | |
| Microsoft Teams | | | | | | |
| Discord | | | | | | |
| VS Code (editor) | | | | | | |
| Cursor (editor) | | | | | | |
| Notion | | | | | | |
| Linear | | | | | | |
| Obsidian | | | | | | |
| IntelliJ / JetBrains | | | | | | |
| Excel (cell edit) | | | | | | |
| Word | | | | | | |
| Terminal / iTerm2 | | | | | | |
| Warp | | | | | | |

### Failure / refusal paths (must NOT silently lose text)

| Scenario | Pass criteria | Last checked | Notes |
|---|---|---|---|
| Long monologue (45+ words, the original bug) | Diff-paste lands at each phase-1 boundary; final stop() flush pastes any remaining tail; nothing is duplicated | | |
| Two-utterance session (speak, pause 3s, speak again, pause to stop) | First ⌘V at first pause; second ⌘V at second pause is *only the new tail*; nothing duplicated; final teardown adds nothing extra | | |
| 1Password master-password field | Cascade refuses; orb fades; **no** failure pill | | |
| Banking site password field | Same as 1Password | | |
| Accessibility revoked mid-dictation | StatusPill flips to "Grant Accessibility…" without restart | | |
| Electron app that silently drops ⌘V | StatusPill shows `.silentDrop`; clipboard has the text 3.5s later | | |
| Cascade returns `.failed` | StatusPill shows `.pasteFailed`; clipboard has the text 3.5s later | | |
| Press ⌥Space, say nothing, wait 8s | No-speech timeout fires; orb fades; no pill, no clipboard touch | | |
| Press ⌥Space twice rapidly | Second press cancels cleanly; no zombie orb | | |
| ⌥Space during a meeting recording | Beeps; no orb; meeting unaffected | | |
| Pause mid-utterance with ⌥P | Orb dims to ~55%, "Paused" replaces listening dots, ring freezes at full; speech is ignored; ⌥P again resumes with a fresh silenceTimeoutSeconds runway and no double-paste | | |
| Pause, wait 30s, resume, finish utterance | No timeout fires while paused; on resume, the *same* session's tail diff-pastes correctly at the next phase-1 boundary | | |
| Escape mid-utterance | Red ring expands ~350 ms over the orb, orb fades, NO paste of the un-committed tail; previously-pasted text in target app is left alone (no undo); no failure pill | | |
| Escape immediately after a phase-1 commit | The text that already pasted stays pasted; nothing else fires; no zombie orb | | |
| Press ⌥Space immediately after Escape | New session starts cleanly with a fresh `savedOnCompleted` (no leakage of cancellation behavior into the next recording) | | |

## Mutter (⌥Space) paste matrix — legacy app coverage

The matrix below was authored for the per-commit paste era. Apps grouped by what we expected the paste cascade to do at the time. Still useful as a coverage checklist: every app that pasted correctly under the old cadence should also paste correctly under commit-once. Treat the AX-first / keystroke split as historical context — under commit-once everything routes clipboard-first.

### Native AX path (AX first, then keystroke, then clipboard)

| App | Short phrase | Long paragraph | Tricky chars | Last checked |
|---|---|---|---|---|
| Notes | | | | |
| Mail (compose window) | | | | |
| Messages | | | | |
| TextEdit | | | | |
| Reminders (new reminder) | | | | |
| Safari (Google search box) | | | | |
| Safari (Gmail compose) | | | | |
| Pages | | | | |

### Keystroke path (skipAX route)

| App | Short phrase | Long paragraph | Tricky chars | Last checked |
|---|---|---|---|---|
| Chrome | | | | |
| Arc | | | | |
| Firefox | | | | |
| Slack | | | | |
| Microsoft Teams | | | | |
| Discord | | | | |
| Notion | | | | |
| Linear | | | | |
| Obsidian | | | | |
| VS Code | | | | |
| Cursor | | | | |
| Figma (text in canvas) | | | | |
| Excel (cell edit) | | | | |
| Excel (formula bar) | | | | |
| Word | | | | |
| PowerPoint | | | | |
| Outlook (compose) | | | | |
| Terminal | | | | |
| iTerm2 | | | | |
| Warp | | | | |
| IntelliJ / any JetBrains | | | | |
| Zed | | | | |
| Raycast command bar | | | | |

### Edge cases worth confirming each release

| Scenario | Pass criteria | Last checked | Notes |
|---|---|---|---|
| Short burst (5 words) | Text lands; dictation auto-stops on silence | | |
| Long burst (45+ words, multiple sentences) | All chunks land in order; no duplicated sentences | | |
| Dictate `equals sum A1 through A10` in Excel | `=SUM(A1:A10)` gets entered as a formula | | |
| Dictate emoji-eligible words | No crash; chunks land correctly | | |
| Accessibility permission NOT granted | Pre-start alert appears; "Start anyway" shows orb but paste visibly fails | | |
| Press ⌥Space twice rapidly | Second press cancels the first cleanly; no zombie orb | | |
| ⌥Space while a meeting recording is in progress | Beeps, no action (guard against concurrent capture) | | |
| Press ⌥Space immediately after app launch (pre-warm race) | Dictation waits on the warm, doesn't bail silently | | |
| Clipboard contents preserved after a clipboard-path paste | What was on the clipboard before is still there after | | |

## Onboarding

Fresh install or `defaults delete com.aaronellis.humdrum Humdrum.onboarded.v1` then launch.

| Panel | Pass criteria | Last checked |
|---|---|---|
| Welcome | Orb breathes; waving hand animates | |
| Features | Two cards explain Meeting Recorder + Mutter | |
| Voice model | Download kicks off on "Download and continue" | |
| Permissions | Granting each flips the row green within ~1s | |
| Folder | Choosing a folder enables auto-save | |
| Success | Checkmark over orb; "Open Humdrum" reaches main window | |

## Canonical phrases

Use these exact strings so "it worked" is unambiguous across runs.

**Short:**
> The quick brown fox jumps over the lazy dog.

**Long (read at normal pace — should trigger ~2 commit boundaries):**
> On Monday morning the team reviewed the launch plan, walked through the rollback procedure, and confirmed that the on-call engineer for the week had their pager turned on. Everyone agreed to meet again Thursday afternoon to sign off on the final go/no-go decision.

**Tricky characters:**
> She said "hello" — with an em dash, a 🎉 emoji, and the formula equals sum of A1 through A10.

(That last one is the Excel formula test; the dictated result in Excel should be `=SUM(A1:A10)` when the focused cell is empty.)

## What to do when a cell fails

1. Note the app version and macOS version in the "Notes" column.
2. Capture a short log sample during the failure:
   ```
   log stream --predicate 'process == "Humdrum"' --level debug
   ```
   Look for `[Humdrum]` entries in the output — the ones we added to `runStep`, `finalizeRemaining`, and `DictationCoordinator.stop()`'s snapshot continuation surface the actual failure mode.
3. If it's a "silently no-ops" failure in a previously-working app, that's probably a vendor update breaking AX. Add the bundle ID to `skipAXBundleIDPrefixes` in `PasteHelper.swift` and re-verify.
4. If it's a keystroke-path app where nothing lands, the usual suspects are: Accessibility permission revoked, the app is sandboxed in a way that blocks synthetic events, or the focused field isn't actually editable.

## Release sign-off

Fill in the date and builder name once the matrix has been walked end-to-end:

- **Release:** (e.g. v2.5)
- **Built by:**
- **Tested on macOS:**
- **Date:**
- **Known failures shipped:** (blank if none)
