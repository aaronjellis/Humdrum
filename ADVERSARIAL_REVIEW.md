# Adversarial review: Mutter + meeting-recording lifecycle

Date: 2026-04-23 (overnight pass)
Scope: `TranscriptionManager`, `DictationCoordinator`, `SetupWindow`, `RecorderWidget`, `AppState`, `PasteHelper`.
Goals you set: (a) no lockouts, (b) start new session immediately after stopping, (c) background processing, (d) snappy Mutter paste.

This is a cold pass — I took the code at face value and asked "what can break." Concerns are ordered by blast radius, not by line number. Fixes are proposed but not applied unless noted; I only applied the `starting` @State reset in `SetupWindow` because it is the exact same class of bug as the `closing` leak you already hit.

---

## 0. Status of uncommitted changes

- `Sources/Humdrum/RecorderWidget.swift` — Stop/X fix: styleMask override removed (SwiftUI's `.hiddenTitleBar` does the right thing), `closing` @State reset on appear. **Not yet committed.**
- `Sources/Humdrum/PasteHelper.swift` — Electron paste hardening: 15 ms pre-delay, explicit 4-event ⌘V (cmd-down, V-down, V-up, cmd-up), 500 ms restore delay. **Not yet committed.**
- `Sources/Humdrum/SetupWindow.swift` — `starting` @State reset on appear, added in this review (same pattern as RecorderWidget's `closing` fix). **Not yet committed.**

Recommend a single commit: "Stop/X button + Electron paste + @State-leak resets." All three are behavior-affecting fixes for bugs you've already seen in testing.

---

## 1. The "locked out after Stop" problem — severity: HIGH

### Root cause

`TranscriptionManager.stop()` at `TranscriptionManager.swift:307` is fundamentally synchronous on its own finalize. It does, in order:

1. `isRecording = false`
2. `isFinalizing = true`
3. cancel transcription/timer/level tasks, stop audio processor
4. **`await finalizeRemaining()`** — runs one more Whisper pass on the trailing audio
5. emit snapshot via `onSessionCompleted`
6. reset manager state
7. `isFinalizing = false`

Between steps 2 and 7, `isBusy == true` (`isBusy = isRecording || isFinalizing || isLoadingModel`). That window is gated behind a full WhisperKit transcribe of the tail buffer, which on `balanced` is ~300–800 ms and on `best` routinely hits 2+ seconds. During this window:

- `SetupWindow.startRecording()` early-returns at line 436 (`!manager.isBusy`).
- The primary button shows `manager.busyReason` → "Finalizing transcript…" — the user sees the lockout, feels it.

You told me "should stop and start a new one almost immediately." Today: they cannot. The "almost immediately" is capped by the slowest tail-pass Whisper will run, with no timeout and no cancel.

### Proposed fix

Move finalize off the manager's critical path. Concretely:

- Capture `audioProcessor`, `whisperKit`, `commits`, `commitSampleIndex`, `startedAt`, `elapsedSeconds`, quality/filter/speakers/hints into a local value right after setting `isRecording = false`.
- Immediately reset `isFinalizing` (or skip setting it at all) so `isBusy` drops.
- Run `finalizeRemaining()` **on the captured local copies** inside a detached `Task`.
- Build the `TranscriptSessionSnapshot` inside that task after the tail pass completes, then call `onSessionCompleted` on `@MainActor`.
- The manager creates a fresh `AudioProcessor` on the next `start()` (it already does this — line 279–281), and `whisperKit` is re-usable across sessions as long as the last `transcribe(...)` has completed.

Caveat: WhisperKit's `transcribe(audioArray:)` is not explicitly documented as reentrant-safe. If two back-to-back sessions fire before the previous tail-pass completes, the second `start()` could invoke WhisperKit while the first's tail-pass is mid-flight. Safer version: serialize via a `Task` chain (same pattern as `AppState.enqueueDiarization`). Pending tail passes then queue up; the manager itself remains unlocked, and a user who hammers Start never sees `isBusy`.

Shape:
```swift
// in stop():
let snapshotInput = SnapshotInput(processor: audioProcessor, kit: whisperKit, ...)
isRecording = false
// isFinalizing stays false — the manager is free from this line forward
audioProcessor = nil   // force start() to rebuild
Task.detached { await finalizeOffline(snapshotInput) }
```

Side benefit: a hung WhisperKit call during finalize no longer locks the UI.

### Also: add a hard cancel

`transcriptionTask?.cancel()` is cooperative — if WhisperKit is mid-transcribe, it doesn't respond. Add a deadline: if `finalizeRemaining()` takes more than, say, 10 seconds, fall through and snapshot whatever we have committed. A hung model pass today means the user is stuck on "Finalizing…" forever, because nothing resets `isFinalizing`.

```swift
await withTaskGroup { group in
    group.addTask { await finalizeRemaining() }
    group.addTask { try? await Task.sleep(for: .seconds(10)) }
    _ = await group.next()      // whichever finishes first
    group.cancelAll()
}
```

---

## 2. Mutter's "few seconds of loading" before paste — severity: HIGH

### Root cause

`DictationCoordinator.start()` at `DictationCoordinator.swift:263`:

1. Shows orb (instant)
2. `await manager.loadModel()` if `manager.needsReload` — cold load of `base.en` is ~700–1500 ms, `small.en` is 2–4 s
3. `await manager.start()` — another few hundred ms to open the audio input and fire the transcription loop
4. User's speech from T+0 to T+(2 and 4) is never heard — `AudioProcessor.audioSamples` only starts accumulating after step 3

Your observation "didn't recognize my voice for a few seconds almost as if it was loading" is exactly this. The first ~2–4 seconds of the user's first Mutter invocation per app-launch are dropped.

### Proposed fix: pre-warm

Three escalating options; pick based on RAM budget:

1. **Cheapest — pre-warm on hotkey install.** In `HumdrumApp.swift`'s `.task` block (line 75), after `dictation.installHotkey()`, kick off a detached `await manager.loadModel()` if the selected quality is bundled/cached. Only auto-load when no download is required (bundled or cached), to avoid silently consuming bandwidth at launch.

2. **Moderate — pre-warm on first menu-bar open or settings open.** Slightly less upfront RAM, but the first ⌥Space press after launch is still slow.

3. **Best UX — pre-warm *and* buffer pre-load speech.** Start the `AudioProcessor` the instant ⌥Space is pressed (before the model finishes loading), and replay the buffered audio through Whisper once the model is ready. Wispr Flow does this. Requires splitting `manager.start()` into `startCapturing()` and `startTranscribing()`.

Recommend #1 for tonight, #3 as the follow-up. #3 makes the "mic is live" signal truthful.

### Second-order: the loaded-model type

`TranscriptionManager.init()` sets `qualityLevel = .balanced` by default. If the user has only downloaded `fast` or has never downloaded anything at all, the pre-warm would attempt a download at launch. Guard on `ModelCache.isBundled(q) || isCached(q)` before auto-warming. The `ModelCache` type is already wired up in `HumdrumApp`.

---

## 3. `starting` / `closing` @State leaks — severity: MEDIUM

### Already fixed

- `RecorderWidget`'s `closing` — the original Stop/X lockout you saw on the second session. Fixed in prior pass via `.onAppear { closing = false }`.
- `SetupWindow`'s `starting` — **same class of bug.** The Setup window has a stable id, the @State persists across dismiss/reopen, and the happy-path `starting = false` on line 471 only runs if the Task reaches its end. Any unhandled path (load fail without hitting `return`, user force-quit, crash) leaves `starting = true` forever, disabling the Start button on subsequent opens. Fixed in this review with `.onAppear { starting = false }` on line 41.

### Still at risk

Any future `@State` flag on a stable-id Window that gates UI. Worth a lint/review pattern: if a `@State Bool` persists across a Window's dismiss/reopen, it either needs `.onAppear` reset or needs to move into an `ObservableObject` with explicit lifecycle. Consider a quick code-search pass for `disabled(.*State.*Bool)` in Window-scoped views.

---

## 4. Mutter paste to Claude desktop — severity: MEDIUM (hardened, unverified)

### What's already done in `PasteHelper.swift:243`

- 15 ms pre-delay between `setString` and ⌘V, so Electron's clipboard-change observers have time to fire before the paste event arrives.
- Explicit 4-event ⌘V (cmd-down, V-down, V-up, cmd-up) — flag-only ⌘V was being silently dropped by Electron renderers that listen for the actual modifier keyDown, not the flag.
- 500 ms restore delay (matches Wispr Flow).

### What may still fail

- **No verification loop.** We post four events and assume the receiving app pasted. Electron, Chromium web views, and sandboxed Mac App Store apps occasionally drop ⌘V despite receiving all four events — focus changed, a modal dialog stole input, OS throttling, etc. `computeDelta` in `DictationCoordinator.swift:414` does *not* detect this; it advances `pastedText` on any `.inserted` result (which only means "we posted the events," not "the app received them").
- **No frontmost-app fingerprint.** We use `setString` into the general pasteboard and ⌘V regardless of target. Web Content extensions on Chrome can intercept the paste event and surface a permission prompt, which would eat the text.
- **Clipboard collision with a concurrent paste.** Rare, but: a user hits ⌥Space while separately ⌘V-ing something. Our pasteboard write races with their paste. Low risk.

### Recommended hardening (not done)

Post-paste verification via AX: after ⌘V, read the focused element's `kAXSelectedTextAttribute` or `kAXValueAttribute` and confirm the delta appeared. If it didn't, re-post. Out of scope for tonight; noted for the follow-up.

### Also noticed

`insertViaClipboard` runs on whatever thread `PasteHelper.paste` was called from. `DictationCoordinator.handleTextUpdate` is `@MainActor`, so in practice it's main — fine. But if someone ever calls `PasteHelper.paste` from a background context, the `NSPasteboard.general` write is not documented as thread-safe and the `DispatchQueue.main.asyncAfter` restore could race with a subsequent write. Worth a comment on `PasteHelper.paste` stating "must be called from main."

---

## 5. Snapshot copy cost on Stop — severity: MEDIUM (latency)

`TranscriptionManager.stop()` line 338–340:

```swift
audioSamples: speakerLabelsEnabled
    ? Array(audioProcessor?.audioSamples ?? [])
    : []
```

For a 60-minute meeting at 16 kHz mono float: 57.6M floats × 4 bytes = **230 MB copy on the main actor.** On an M-series Mac that's ~50–100 ms; on an older Intel or constrained machine, multiples of that. Feels like a hang when tapping Stop at the end of a long meeting.

### Proposed

If `speakerLabelsEnabled`, hand off the `[Float]` via move semantics — don't `Array(...)` copy it. `AudioProcessor.audioSamples` appears to be its own storage; if we can drain it (transfer ownership) rather than copy, cost drops to near-zero. Failing that, do the copy inside the background snapshot Task suggested in §1, not on main.

Secondary: even the `commits` copy on line 341 is cheap for normal sessions (hundreds of entries at most), but skip it if not labeling. Already conditional — good.

---

## 6. Auto-save on main actor — severity: LOW (latency)

`AppState.autoSaveIfEnabled` → `TranscriptExporter.write` is synchronous disk I/O on the `@MainActor`. For a 10-page transcript it's a few ms; for a 3-hour meeting with speakers labeled, it can be tens of ms plus potential iCloud sync latency if the default folder is in iCloud Drive.

Shift to `Task.detached` or an off-main queue. This also protects the UI from a temporary disk-full condition blocking the main thread.

---

## 7. Silence-monitor / no-speech timeout — severity: LOW

`DictationCoordinator.evaluateAudio()` at line 433 polls every 200 ms. The eight-second no-speech timeout (`noSpeechTimeoutSeconds = 8.0`) is counted from `sessionStartedAt`, which is reset on line 337 after model load. Good — the model-download case won't burn the budget anymore.

### Edge case

If the user presses ⌥Space, the orb appears, but `manager.start()` silently fails (mic denied, model load raced), `isDictating` stays true for the full 8 seconds. The user speaks, nothing pastes, then the orb disappears and they wonder what happened. Two fixes:

1. Surface mic-denied as a visible overlay pill (same mechanism as the accessibility pill).
2. If `manager.start()` completes without setting `manager.isRecording = true`, bail immediately with a beep or a pill update rather than waiting for the silence timeout.

Today, `manager.start()` sets `status` to the mic-denied message but doesn't surface it to the dictation overlay. `DictationOverlayView` probably only reads `manager.isRecording`. Worth checking: if `isRecording` is false the moment `manager.start()` returns, stop the coordinator right there.

---

## 8. `computeDelta` silently drops on divergence — severity: LOW

`DictationCoordinator.swift:414`: if `newText` doesn't prefix `pastedText`, we skip and wait. This is the right policy for temporary Whisper rewrites. But if the divergence is permanent (noise filter trimmed a committed chunk, user said something ambiguous and Whisper rewrote it), the user loses the diff forever — no retry, no warning.

Proposal: if divergence persists for >2 seconds of wall clock with new commits arriving, flash a subtle "transcription realigned" signal on the overlay and re-sync `pastedText = manager.confirmedText` (accepting that we'll miss one chunk). Better than silent stuck.

---

## 9. Diarization worker is serial by design — severity: LOW

`AppState.enqueueDiarization` chains via `_ = await previous?.value`. This is correct for avoiding concurrent FluidAudio calls but means a single pathological session (OOM, corrupt audio) can block the label display for *every* subsequent session.

Safeguards to add:

- A per-job timeout (say, 10× the session duration, capped at 30 min).
- Catch-all around `diarization.diarize` that always unblocks `diarizingSessionIds.remove(sessionId)` (already handled by `defer`, good) AND always allows the next chained task to proceed (already handled because the `Task` returns normally after error — good).
- Consider making the chain one-deep: if a diarization job is already in flight, enqueue at most one more. Protects against users recording 20 short sessions back-to-back and queuing up 20 diarization jobs.

---

## 10. `refreshInputDevices()` on main actor in `start()` — severity: LOW

`TranscriptionManager.start()` line 286 re-enumerates CoreAudio devices synchronously. `AudioProcessor.getAudioDevices()` on Intel Macs with many USB audio devices can take 20–50 ms. Harmless but avoidable: refresh when SetupWindow opens, cache for 2–3 seconds, or do it off-main.

---

## 11. `tccutil` call blocks main — severity: LOW

`DictationCoordinator.resetAccessibilityPermission` uses `Process.waitUntilExit()` on `@MainActor`. `tccutil reset` is usually instant, but if the TCC daemon is wedged the UI freezes. Move to a detached task with a deadline.

---

## 12. Electron-specific: Claude desktop paste pipeline

Observed so far: flag-only ⌘V was dropped, the explicit 4-event sequence fixed it (unverified by user). Claude desktop is Electron with specific quirks worth documenting:

- The renderer sometimes lazy-reads the clipboard. 500 ms restore is the known-safe value.
- The renderer listens for `keydown`/`keyup` events on `document` — synthetic events must land on the focused `contenteditable`. `.cghidEventTap` targets the hardware tap, which Electron respects.
- Electron drops synthetic key events if the app is not frontmost. If the user ⌥Space-triggers Mutter while Claude desktop is not frontmost, paste silently no-ops. `NSApp.frontmostApplication` is Claude at the time of paste because the orb is a `.nonactivatingPanel` — confirmed via `DictationOverlay.swift:13,36`. Good.
- If the user switches apps *during* the paste sequence, events land on the new frontmost. Rare but possible — a sub-100 ms user-induced race.

No change recommended. Just noting the shape.

---

## Recommended fix order for tomorrow

1. **Commit the three pending fixes** (RecorderWidget, PasteHelper, SetupWindow). All are low-risk behavior fixes for bugs you've already seen.
2. **Un-block Stop → Start latency (§1).** Move finalize off the manager's critical path. This is the single biggest win for "snappy back-to-back recording."
3. **Pre-warm Whisper on hotkey install (§2).** Fixes the first-Mutter-per-launch delay you reported.
4. **Add a deadline to `finalizeRemaining()` (§1).** Insures against a hung WhisperKit call.
5. **Surface mic-denied immediately in Mutter (§7).**
6. **Background the snapshot copy (§5).** Needed before anyone records a multi-hour session with speakers on.

Items 1–4 together deliver the "never lock user out, record back-to-back instantly" experience you asked for. Items 5–6 harden the long-tail cases.

---

## Verification checklist after fixes land

- [ ] Start recording, Stop, Start again within 500 ms — second session records audio (not just UI).
- [ ] Start Mutter immediately after app launch, begin speaking within 1 s — all speech lands in target field (verifies pre-warm).
- [ ] Start recording with `best` quality, record 5 minutes, Stop — next Start available within 500 ms (verifies finalize-offline).
- [ ] Pull network mid-stop, verify `isFinalizing` resets within 10 s (verifies deadline).
- [ ] Mutter into Claude desktop, verify text lands (verifies Electron paste fix).
- [ ] Mutter into Slack, Discord, Teams, VS Code, Notes, Safari — all paste (regression check).
- [ ] Revoke Accessibility mid-Mutter-session, verify overlay pill appears (verifies `.failed` → `refreshAccessibilityStatus`).
- [ ] Deny mic permission, press ⌥Space — overlay signals error within 1 s (verifies §7).

---

## Code-locations index

| Concern | File | Line |
|---|---|---|
| Stop → lockout window | `TranscriptionManager.swift` | 307–357 |
| `isBusy` gate | `TranscriptionManager.swift` | 692–694 |
| Mutter pre-load delay | `DictationCoordinator.swift` | 300–312 |
| `starting` @State leak (fixed) | `SetupWindow.swift` | 41 (new onAppear) |
| `closing` @State leak (fixed prior) | `RecorderWidget.swift` | 143 |
| Electron paste sequence | `PasteHelper.swift` | 243–295 |
| Snapshot main-actor copy | `TranscriptionManager.swift` | 327–342 |
| Auto-save main-actor I/O | `AppState.swift` | 173–207 |
| Diarization serial chain | `AppState.swift` | 253–273 |
| `computeDelta` divergence | `DictationCoordinator.swift` | 414–420 |
| `refreshInputDevices` main-actor | `TranscriptionManager.swift` | 286 |
