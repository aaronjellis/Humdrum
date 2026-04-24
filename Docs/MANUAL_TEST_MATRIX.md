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

## Mutter (⌥Space) paste matrix

For each target app, focus a text field, press ⌥Space, read the test phrase aloud, wait for silence-timeout to end dictation, and check the result.

Apps are grouped by what we expect the paste cascade to do for them — if an app in the "native AX" group starts failing, that's a hint that our AX-first path has a new edge case; if an app in the "keystroke" group fails, the `skipAXBundleIDPrefixes` routing probably dropped it.

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
   Look for `[Humdrum]` entries in the output — the ones we added to `runStep`, `finalizeRemaining`, and `DictationCoordinator.handleTextUpdate` surface the actual failure mode.
3. If it's a "silently no-ops" failure in a previously-working app, that's probably a vendor update breaking AX. Add the bundle ID to `skipAXBundleIDPrefixes` in `PasteHelper.swift` and re-verify.
4. If it's a keystroke-path app where nothing lands, the usual suspects are: Accessibility permission revoked, the app is sandboxed in a way that blocks synthetic events, or the focused field isn't actually editable.

## Release sign-off

Fill in the date and builder name once the matrix has been walked end-to-end:

- **Release:** (e.g. v2.5)
- **Built by:**
- **Tested on macOS:**
- **Date:**
- **Known failures shipped:** (blank if none)
