# Mutter paste pivot — implementation plan

**Date:** 2026-04-25
**Status:** Ready to execute
**Companion doc:** [mutter-paste-research.md](./mutter-paste-research.md)

## What we're shipping

Three coupled changes in one PR. They're tightly interdependent and don't earn their keep individually.

1. **Cadence pivot to commit-once** — paste exactly one ⌘V at end of dictation. Delete the per-Whisper-commit paste loop entirely. (Fixes the bug.)
2. **Magic-orb word ticker** — words flow through the orb interior in real time so dictation feels alive even though paste is now end-of-utterance. (Hides the new latency.)
3. **Failure-fallback pill** — if paste fails or the receiving app silently drops the text, surface a toast: *"On your clipboard — ⌘V to insert."* Never silently lose a dictation. (Belt-and-braces reliability.)

No feature flag. The old path is broken, we're not preserving it. Roll back via git if needed. Default is the new behavior, full stop.

---

## Architectural shape

```
DictationCoordinator
├── start()                 [unchanged scaffolding, drops commitsSink]
├── stop()                  [now: await finalize → paste once → handle result]
├── @Published wordStream   [ordered append-only feed of confirmed words for the ticker]
└── @Published pasteOutcome [.pending | .succeeded | .failed | .silentDrop]

PasteHelper / RealPasteBackend
├── insertViaClipboard      [3s restore (was 500ms), restore is now skippable]
└── insertViaKeystrokes     [unchanged tail fallback]

DictationOverlayView
├── AudioVisualizer         [unchanged]
├── WordTicker              [new — flows ticker words right→left, fades at left edge]
└── StatusPill              [unified: permission warning | paste-failure toast]
```

Pure-logic pieces lifted to HumdrumCore so they're testable without AppKit.

---

## A. Cadence pivot to commit-once

### What's deleted from `DictationCoordinator.swift`

- `pastedText` field (line 96)
- `commitsSink` field (line 103)
- `handleTextUpdate(_:)` (lines 470–495)
- `computeDelta(_:)` (lines 501–507)
- `pasteFinalDelta(from:)` (lines 457–466) — its logic moves into `stop()`
- The `commitsSink` initialization in `start()` (lines 354–358)
- The `commitsSink?.cancel()` calls in `stop()` (line 413) and the recording-failed cleanup (line 379)
- The `manager.onSessionCompleted = { ... pasteFinalDelta }` install (lines 342–344) — replaced by direct snapshot capture

The `lastChunkPastedAt` published property stays — it now fires once at end-of-paste, and the orb's existing ring-pulse animation gives the user a single satisfying confirmation flash. (The animation is already non-deterministic about whether it pulses once or many times; we just give it one trigger now.)

### What's added / changed

**New `stop()` flow.** Instead of pasting via Combine sink during the session, `stop()` becomes the single paste site:

```
1. Cancel sinks, cancel silence task. (existing)
2. Capture the final snapshot via the manager's onSessionCompleted callback.
   The callback's only job is to set a local `var finalSnapshot: TranscriptSessionSnapshot?`.
3. await manager.stop().
4. await manager.pendingFinalize?.value with a 5s deadline (existing 30s deadline is too long for orb-hold UX — we cap at 5s here and paste whatever we have).
5. Read finalText from finalSnapshot?.transcriptText, fall back to manager.confirmedText if the snapshot didn't arrive in time.
6. If finalText is empty, skip paste entirely (user hit ⌥Space twice with nothing said).
7. Call PasteHelper.paste(finalText) once. Record outcome on self.pasteOutcome.
8. Restore all manager settings (existing).
9. Hold the orb for an outcome-dependent linger:
   - .succeeded: 250ms (gives ⌘V time to paint, then orb fades — slightly longer than today's 120ms because we now want users to see the ring-pulse confirmation)
   - .silentDrop or .failed: 4500ms (so the failure pill is visible long enough to read)
10. Hide overlay.
```

The `pendingFinalize` cap from 30s → 5s for the dictation context is an explicit choice: in practice the tail Whisper pass on dictation-mode thresholds (`maxSegmentSeconds: 7.0`) finalizes in well under a second; the existing 30s cap exists for meeting mode where windows are larger. Don't change `manager.pendingFinalize`'s underlying deadline; just enforce a tighter wait on the dictation side via `Task.race`-style timeout.

**Final-snapshot capture.** Replace the existing callback install with a Continuation-style hand-off:

```swift
// in stop(), before `await manager.stop()`:
let snapshot = await withCheckedContinuation { (cont: CheckedContinuation<TranscriptSessionSnapshot?, Never>) in
    // 5s safety timeout
    let timeout = Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        cont.resume(returning: nil)
    }
    manager.onSessionCompleted = { snap in
        timeout.cancel()
        cont.resume(returning: snap)
    }
    Task { await manager.stop() }
}
```

This collapses three previously-separate things (the callback install, the `await manager.stop()`, and the `await manager.pendingFinalize?.value`) into a single awaited point with a deterministic deadline.

**Paste call site.** Single call:

```swift
let finalText = (snapshot?.transcriptText ?? manager.confirmedText)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard !finalText.isEmpty else {
    pasteOutcome = .succeeded   // nothing to paste = trivial success
    return
}
let result = PasteHelper.paste(finalText)
pasteOutcome = (result == .inserted) ? .succeeded : .failed
lastChunkPastedAt = Date()
```

(The `.silentDrop` case is detected by the AX verification path described in Section C — the call site there will downgrade `.succeeded` to `.silentDrop` if verification fails.)

### Lengthen restore window

In `Sources/Humdrum/PasteHelper.swift` line 291, change:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    restorePasteboard(pasteboard, snapshot: saved)
}
```

to:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
    restorePasteboard(pasteboard, snapshot: saved)
}
```

Update the doc comment on lines 286–290 to reference Superwhisper's 3s window and remove the Wispr-Flow-specific `~500ms` justification (which was for the streaming-paste world we're leaving).

### Skippable restore

We need to suppress the restore in the `.failed` and `.silentDrop` paths so the dictation text stays on the clipboard for the user's manual ⌘V. Two options:

1. **Add a `restoreClipboard: Bool` parameter to `insertViaClipboard`.** Caller decides. Cleaner.
2. **Expose a `cancelPendingRestore()` on the backend.** Caller cancels the scheduled restore after detecting failure.

Go with option 1. Modify `PasteBackend` protocol in `Sources/HumdrumCore/PasteCascade.swift`:

```swift
public protocol PasteBackend {
    func insertViaClipboard(_ text: String, restoreClipboard: Bool) -> Bool
    func insertViaKeystrokes(_ text: String) -> Bool
}
```

Then `PasteCascade.execute` always passes `restoreClipboard: true` for the `.clipboardFirst` happy path. The `DictationCoordinator` flow that suppresses restore lives one level up: when AX verification fails (Section C), we *re-set* the clipboard to the dictation text post-hoc. This is simpler than threading `restoreClipboard: false` through the cascade.

**Resolution:** keep `PasteBackend` unchanged; instead, in the silent-drop / failed path, the coordinator does:

```swift
if pasteOutcome != .succeeded {
    // Clipboard restore is already in flight (3s deadline). Beat it
    // by re-writing our text to the clipboard now and again at +3.5s.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(finalText, forType: .string)
    Task {
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalText, forType: .string)
    }
}
```

This is uglier than a threaded boolean but keeps `PasteBackend` and the cascade tests untouched. Rewrite the comment around it to make the rationale explicit.

---

## B. Magic-orb word ticker

### What the user gets to see

Inside the orb's interior (overlaid on the audio visualizer at the same z-level), words appear one at a time at the **right edge**, slide leftward over ~700ms with `.easeOut`, and fade their opacity from 1.0 → 0.0 along the way. Once opacity hits zero, the word is removed from the rendering list.

If the user is silent, no words appear and the orb is just the visualizer (current behavior).

If the user speaks fast, multiple words exist simultaneously, each at a different stage of its slide — the visual is a stream of words flowing through the orb. Dense speech gives a denser stream; trailing-off speech gives a sparser tail. The metaphor is "the orb sees the words pass through it."

### The data model: monotonic word stream

The Plan agent's first draft tracked words by text content. That's wrong — repeated words ("the the the") would dedupe. We track by **sequence index**, not text.

Add to `Sources/HumdrumCore/`, new file `WordStream.swift`:

```swift
public struct StreamedWord: Identifiable, Equatable, Sendable {
    public let id: Int          // monotonic per dictation session
    public let text: String
    public let bornAt: Date     // wall-clock when first observed
}

public struct WordStream: Equatable, Sendable {
    public private(set) var words: [StreamedWord] = []
    private var nextId: Int = 0

    /// Update the stream from a Whisper-style monotonic confirmed text.
    /// `confirmed` is expected to be append-only; if it shrinks (Whisper
    /// rewrites prior hypothesis), we keep the existing word IDs for the
    /// stable prefix and re-emit only the newly-arriving suffix.
    /// Returns the words that were newly appended this call.
    public mutating func ingest(confirmed: String, now: Date) -> [StreamedWord] {
        let tokens = confirmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        // Find the longest stable prefix between existing words and tokens.
        var prefixLen = 0
        let cmp = min(words.count, tokens.count)
        while prefixLen < cmp && words[prefixLen].text == tokens[prefixLen] {
            prefixLen += 1
        }

        // Anything beyond prefixLen in `words` is stale — Whisper rewrote it.
        // We keep them in the rendering list (they're already mid-fade) but
        // truncate the canonical word list so further ingests align.
        let staleTail = Array(words[prefixLen...])
        words.removeSubrange(prefixLen...)

        // Append newly-arrived tokens with fresh monotonic IDs.
        var appended: [StreamedWord] = []
        for t in tokens.dropFirst(prefixLen) {
            let w = StreamedWord(id: nextId, text: t, bornAt: now)
            nextId += 1
            words.append(w)
            appended.append(w)
        }

        _ = staleTail   // intentionally discarded from the canonical list;
                        // stale words finish their existing fade-out animation
                        // in the view layer (they're keyed by id, not text).

        return appended
    }

    public mutating func reset() {
        words.removeAll()
        nextId = 0
    }
}
```

Pure logic, fully unit-testable. Tests in `Tests/HumdrumCoreTests/WordStreamTests.swift` cover:
- monotonic append on growing confirmed text
- repeated-word streaming (`"the the the"` produces three distinct StreamedWords)
- prefix-stable rewrite (Whisper revising the last word doesn't disturb earlier IDs)
- reset behavior

### Coordinator wiring

Add to `DictationCoordinator`:

```swift
@Published private(set) var wordStream = WordStream()
private var streamSink: AnyCancellable?
```

In `start()`:

```swift
wordStream.reset()
streamSink = manager.$confirmedText
    .receive(on: DispatchQueue.main)
    .sink { [weak self] text in
        guard let self else { return }
        _ = self.wordStream.ingest(confirmed: text, now: Date())
        self.objectWillChange.send()
    }
```

In `stop()` and the recording-failed path: `streamSink?.cancel(); streamSink = nil; wordStream.reset()` (reset only after the orb hides, so the ticker doesn't pop empty as the orb fades out).

### View layer

New file `Sources/Humdrum/WordTicker.swift`. Sketch:

```swift
struct WordTicker: View {
    @ObservedObject var dictation: DictationCoordinator
    let orbDiameter: CGFloat

    private let slideDuration: TimeInterval = 0.7
    private let slideDistance: CGFloat   // = orbDiameter * 0.45 (computed)
    private let fontSize: CGFloat        // = max(10, orbDiameter * 0.085)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            ZStack(alignment: .trailing) {
                ForEach(visibleWords(now: ctx.date)) { word in
                    let p = progress(word, now: ctx.date)
                    Text(word.text)
                        .font(.system(size: fontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(1.0 - p))
                        .offset(x: -p * slideDistance)
                        .blur(radius: p * 1.2)              // subtle veil as it fades
                        .id(word.id)
                }
            }
            .frame(width: orbDiameter * 0.78, height: fontSize * 1.6)
            .clipShape(Capsule())                            // soft edge clip
            .allowsHitTesting(false)
        }
    }

    private func progress(_ w: StreamedWord, now: Date) -> Double {
        min(1.0, max(0.0, now.timeIntervalSince(w.bornAt) / slideDuration))
    }

    private func visibleWords(now: Date) -> [StreamedWord] {
        // Keep words that haven't finished their fade. Even Whisper-stale
        // words ride out their existing animation — we don't yank them.
        dictation.wordStream.words.filter { progress($0, now: now) < 1.0 }
        // Also need to retain the "stale tail" that ingest() pruned, since
        // those still want to finish fading. Track via a separate
        // @Published rolling buffer in the coordinator OR derive the
        // visible set from the words `appended` accumulator. See below.
    }
}
```

The visible-set bug is real: when Whisper rewrites the tail, those words leave `wordStream.words` but should still finish their fade. Fix by maintaining a separate **visual buffer** in the coordinator that tracks every word ever emitted in the session:

```swift
@Published private(set) var visualWords: [StreamedWord] = []

// in the streamSink:
let appended = wordStream.ingest(confirmed: text, now: Date())
visualWords.append(contentsOf: appended)
// Garbage-collect: drop words whose fade has long since completed.
let cutoff = Date().addingTimeInterval(-1.5)
visualWords.removeAll { $0.bornAt < cutoff }
```

Then `WordTicker` reads from `dictation.visualWords` rather than `wordStream.words`. Stale-by-rewrite words ride out their natural fade; the GC step keeps memory bounded.

### Hit-testing & focus

The dictation panel is already `nonactivatingPanel` and `canBecomeKey == false` (`DictationPanel`, lines 13–36). Adding the WordTicker is purely visual. Set `.allowsHitTesting(false)` on the ticker so it doesn't compete for any cursor events.

### Sizing & typography

The orb is sized by `DictationOverlayController` (need to verify dimensions in the file). Use the orb's diameter as the basis for ticker dimensions. Recommend SF Rounded at ~8.5% of orb diameter (e.g. 14pt for a 165pt orb) — large enough to read, small enough that 4–6 words fit visibly mid-flow.

### Where it sits in the view hierarchy

In `DictationOverlayView`, place `WordTicker` as an overlay on the `AudioVisualizer` (line 131-ish), centered on the orb. The visualizer keeps its current behavior; the ticker rides on top with `.compositingGroup()` and a slight inner-glow background (a thin radial gradient mask) so words don't visually fight the visualizer's level meters.

---

## C. Failure-fallback pill (with cheap silent-drop detection)

### Detection

Two failure modes, two ways to catch them:

1. **`PasteResult.failed`** — covers permission refusal, password-field refusal, CGEvent source failure. Already correct.
2. **Silent drop** — `insertViaClipboard` returned true, ⌘V was posted, but the receiving app didn't actually accept the text. Today this is invisible.

For (2), do a cheap AX verification post-paste. The full-fat version (poll `kAXSelectedTextAttribute` or `kAXValue` for length growth across multiple ticks) is expensive and prone to its own failure modes on hardened web views. A lighter version that's good enough for v1:

- Read the focused element's `kAXNumberOfCharactersAttribute` (or `kAXValue` length) **immediately before** posting ⌘V.
- After ~250ms (single sleep on a background queue), read it again.
- If the length grew by `>= dictation.utf16.count` → confirmed inserted.
- If the length didn't change → silent drop.
- If the read failed at either step (Electron renderers often refuse this attribute) → unknown; treat as `.succeeded` to avoid false alarms.

Add to `PasteHelper.swift`, alongside `focusedAXRole()`:

```swift
private static func focusedTextLength() -> Int? {
    let system = AXUIElementCreateSystemWide()
    var focusedRaw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
          let focusedRaw else { return nil }
    let element = focusedRaw as! AXUIElement

    var lenRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &lenRaw) == .success,
       let n = lenRaw as? Int {
        return n
    }
    // Fallback: AXValue string length.
    var valRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRaw) == .success,
       let s = valRaw as? String {
        return s.count
    }
    return nil
}
```

Coordinator post-paste verification (called after `PasteHelper.paste`):

```swift
private func verifyInsertion(_ text: String, before: Int?) async -> PasteOutcome {
    guard let before else { return .succeeded }   // unknown baseline → no false alarm
    try? await Task.sleep(nanoseconds: 250_000_000)
    guard let after = PasteHelper.focusedTextLength() else { return .succeeded }
    return (after - before) >= text.count ? .succeeded : .silentDrop
}
```

The 250ms sleep is the minimum that comfortably handles Electron's lazy-read pattern. Any longer and the orb teardown lingers visibly; any shorter and we'll trip false-positive silent-drops on slow renderers.

### Outcome propagation

```swift
public enum PasteOutcome: Equatable, Sendable {
    case succeeded         // happy path
    case failed            // cascade refused or errored
    case silentDrop        // cascade reported success but verification disagreed
}
```

In `DictationCoordinator`:

```swift
@Published private(set) var pasteOutcome: PasteOutcome = .succeeded
```

In `stop()`:

```swift
let before = PasteHelper.focusedTextLength()
let result = PasteHelper.paste(finalText)
switch result {
case .inserted:
    pasteOutcome = await verifyInsertion(finalText, before: before)
case .failed:
    pasteOutcome = .failed
}
```

### The pill UI

`DictationOverlayView` currently has a permission-warning pill (lines 152–155, 287–299). Generalize it into a single `StatusPill` subview that handles three states:

- Permission missing — existing copy, existing styling
- Paste failed — *"Couldn't paste. Text on your clipboard — ⌘V to insert."* + warning icon, warning color
- Silent drop — *"That app didn't take the paste. Text on your clipboard — ⌘V to insert."* + warning icon, warning color
- (Default) — hidden

The pill auto-fades in via the existing `.transition(.opacity.combined(with: .move(edge: .bottom)))` pattern. Auto-dismiss is handled by the orb's overall lifecycle: in the failure paths, `stop()` lingers the orb for 4.5s before hiding (Section A), so the pill is naturally visible long enough to read and act on.

If the user ⌘Vs while the orb is still up: that's fine, the clipboard has the text. We don't need to detect their ⌘V or auto-dismiss early.

### Clipboard preservation in the failure path

Section A's "skippable restore" decision: when `pasteOutcome != .succeeded`, the coordinator re-writes the dictation text to `NSPasteboard.general` and re-writes it again at +3.5s to outlast the cascade's 3s restore. The first re-write happens immediately (so a fast-fingered user can ⌘V right away even before the cascade restore has run); the second re-write fires after the cascade restore runs, ensuring the dictation text wins the race.

---

## Cross-cutting concerns

### Test strategy

**HumdrumCore (pure logic, no AppKit):**
- `WordStreamTests.swift` — new. Cover ingest monotonicity, repeated words, prefix-stable rewrite, reset.
- `PasteCascadeTests.swift` — existing, no changes. Cascade decisions are unaffected.

**Humdrum (executable target — these need a fake `TranscriptionManager`-shaped seam, which doesn't exist today; we'll add a protocol):**
- `DictationCoordinatorTests.swift` — new. Cover:
  - `stop()` calls `paste()` exactly once with the final transcript
  - `stop()` falls back to `manager.confirmedText` when the snapshot doesn't arrive within 5s
  - `pasteOutcome` is `.failed` when `PasteHelper.paste` returns `.failed`
  - `pasteOutcome` is `.silentDrop` when verification reports no growth
  - `visualWords` GC trims words past their fade window

**Manual matrix:**
- TextEdit (Cocoa happy path)
- Notes (Cocoa, RTF complications)
- Chrome address bar (Chromium hardened input)
- Slack message composer (Electron, the original motivating case)
- Claude desktop chat input (Electron with debounced clipboard observers)
- VS Code editor (Electron + Monaco)
- Terminal.app prompt (Cocoa with no clipboard read)
- 1Password's master-password field (refusal path — should never paste, pill should NOT fire because the cascade refuses pre-paste)
- A 30-second monologue (the actual reproduction case for the original bug)

Add this to `docs/MANUAL_TEST_MATRIX.md` as a "Mutter dictation v2" section.

### TranscriptionManager seam

`DictationCoordinator` depends on the concrete `TranscriptionManager`. To unit-test the new `stop()` flow with a fake snapshot source, we need to extract the surface used:

```swift
protocol DictationTranscriptSource: AnyObject {
    var confirmedText: String { get }
    var hypothesisText: String { get }
    var pendingFinalize: Task<Void, Never>? { get }
    var onSessionCompleted: ((TranscriptSessionSnapshot) -> Void)? { get set }
    func start() async
    func stop() async
    // … etc.
}
```

Have `TranscriptionManager` conform; have `DictationCoordinator` hold an `any DictationTranscriptSource`. This is a refactor but it's small and unblocks proper testing of the new orchestration. Recommend doing it.

### Backward compatibility

- `Humdrum.dictation.hotkeyEnabled` and `Humdrum.dictation.silenceTimeout` UserDefaults keys: untouched.
- No new UserDefaults keys (we deliberately skipped the feature flag).
- `commitThresholds.dictation` values: untouched.
- Mid-dictation upgrade: `start()` resets state cleanly — no migration needed.

### Risk register

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| `pendingFinalize` exceeds 5s on a slow first-time model load | Low — model is loaded before recording begins | Fall back to `manager.confirmedText` in `stop()` |
| AX `kAXNumberOfCharactersAttribute` returns nil on most Electron apps | High — known behavior | Treat nil as "unknown, assume succeeded" — no false silent-drop pills |
| Word ticker animation jank on long dictations (200+ words emitted) | Low | `visualWords` GC drops words past fade window; visible set stays bounded |
| Ticker-fading words fight visualizer brightness | Medium | Ticker has `.compositingGroup()` and a subtle radial darkening underlay so contrast survives |
| Re-write-clipboard-after-failure races with paste manager apps (Alfred, Raycast, Paste) | Medium | The double-write pattern (+0ms and +3.5s) catches both pre- and post-restore reads. Document as known-limitation: heavy clipboard managers may show a transient duplicate entry. |
| 250ms verification delay perceptibly lengthens "paste then orb fade" | Low | The 250ms sits inside the existing 250ms post-paste linger we're already adding; net cost is zero |
| User dictates into a password field → cascade refuses → no pill is shown | Intentional — refusal is silent by design (matches Wispr/Superwhisper) | None needed, but add a one-line dev comment in the cascade noting this is deliberate |

### Out of scope for this PR

- Push-to-talk (hold-⌥Space) activation mode
- Per-app paste policy overrides
- Spoken-to-written text cleanup pass (an LLM rewrite step, à la VoiceInk)
- Hands-free always-on listening mode
- Any iOS counterpart

These are all reasonable future work. None of them belong in the reliability fix.

---

## Implementation sequence

The plan below assumes one engineer (likely you, in a single sitting) and aims for ~1 day of work, including manual test passes.

### Phase 1 — Pure logic (HumdrumCore)
1. Create `Sources/HumdrumCore/WordStream.swift` with `StreamedWord` + `WordStream`.
2. Create `Tests/HumdrumCoreTests/WordStreamTests.swift`. Cover the four cases from the test plan.
3. Run `swift test` — all green before moving on.

### Phase 2 — Paste pipeline
4. In `Sources/Humdrum/PasteHelper.swift`: extend the restore delay to 3.0s (line 291). Update the doc comment.
5. Add `focusedTextLength()` private static. Document its nil-on-Electron behavior.
6. No changes to `PasteCascade` or `PasteBackend` — keep the cascade tests green.

### Phase 3 — Coordinator surgery
7. Define `PasteOutcome` enum in `Sources/HumdrumCore/PasteCascade.swift` (or a new file). It's pure-logic, lives in core.
8. Define `DictationTranscriptSource` protocol; conform `TranscriptionManager` (mechanical, no behavior change).
9. In `DictationCoordinator`:
   - Add `@Published wordStream`, `@Published visualWords`, `@Published pasteOutcome`.
   - Add `streamSink` and wire it in `start()`.
   - Delete `pastedText`, `commitsSink`, `handleTextUpdate`, `computeDelta`, `pasteFinalDelta`.
   - Rewrite `stop()` per Section A's flow.
   - Add `verifyInsertion(_:before:)` helper.
   - Add the failure-path clipboard re-write logic.
10. Add `Tests/HumdrumTests/DictationCoordinatorTests.swift` — covers the four cases from the test plan, using the fake transcript source.

### Phase 4 — UI
11. Create `Sources/Humdrum/WordTicker.swift` per Section B's sketch.
12. Generalize the existing permission pill in `DictationOverlay.swift` into a `StatusPill` view that handles permission / failed / silent-drop states.
13. In `DictationOverlayView` body, embed `WordTicker` as an overlay on the audio visualizer; embed `StatusPill` below the orb.

### Phase 5 — Manual + integration testing
14. Walk the manual test matrix above. Note any app-specific surprises.
15. Update `docs/MANUAL_TEST_MATRIX.md` with the Mutter v2 row.
16. Smoke-test the silence auto-stop and no-speech timeout — both should still work end-to-end with the new paste cadence.
17. Smoke-test password-field refusal — the orb should still appear, dictation should still record, and *no* paste-failure pill should appear (refusal is intentionally silent).

### Phase 6 — Polish
18. Review the doc comments in `DictationCoordinator.swift` — the file's header at lines 9–24 needs to be rewritten to reflect the new commit-once cadence.
19. Update `PasteHelper.swift`'s file header comment (lines 6–44) to drop the per-commit framing.
20. Update `PasteCascade.swift`'s file header (lines 22–44) similarly.
21. Final code review pass — anything that mentions "incremental paste" or "delta" in comments should now be removed.

---

## Files affected

**New**
- `Sources/HumdrumCore/WordStream.swift`
- `Sources/Humdrum/WordTicker.swift`
- `Tests/HumdrumCoreTests/WordStreamTests.swift`
- `Tests/HumdrumTests/DictationCoordinatorTests.swift`

**Modified**
- `Sources/Humdrum/DictationCoordinator.swift` — substantial: delete the per-commit machinery, rewrite `stop()`, add ticker + outcome state.
- `Sources/Humdrum/DictationOverlay.swift` — generalize the pill, embed the ticker.
- `Sources/Humdrum/PasteHelper.swift` — restore delay 0.5s → 3.0s, add `focusedTextLength()`.
- `Sources/HumdrumCore/PasteCascade.swift` — add `PasteOutcome` (or new file).
- `Sources/Humdrum/TranscriptionManager.swift` — minor: conform to `DictationTranscriptSource`. No behavior change.
- `docs/MANUAL_TEST_MATRIX.md` — append v2 dictation matrix.

**Untouched**
- `Tests/HumdrumCoreTests/PasteCascadeTests.swift` — cascade decisions are unchanged.
- Everything in `Sources/HumdrumCore/` not listed above.

---

## Why this design

A few non-obvious choices that are worth making explicit:

**No feature flag.** The old path is broken; preserving it costs ongoing maintenance attention with no offsetting value. You're the only user. Roll back with `git revert` if needed. Feature flags earn their keep when you have heterogeneous users, A/B telemetry, or rollout staging — none of which apply.

**No Settings UI for any of this.** The new behavior is the right behavior; we don't need to ask the user which mode they want.

**Cheap AX verification, not aggressive polling.** A single read 250ms post-paste is a 90% solution at 10% of the cost. Aggressive polling (read every 50ms for 1 second, look for any growth) catches more silent drops but trips on slow renderers and adds a perceptible orb-linger.

**Re-write the clipboard after failure rather than thread `restoreClipboard: false` through the cascade.** Keeps `PasteBackend` and `PasteCascade` and their tests untouched; localizes the failure-handling weirdness to the coordinator.

**Word ticker tracks by sequence index, not text.** Repeated words are common in spoken English (*"like, like, you know, the the the thing"*). Dedup-by-text would visibly misbehave.

**`visualWords` separate from `wordStream.words`.** Whisper rewrites the tail occasionally; we don't want that to yank already-animating words off-screen. The visual buffer outlives the canonical buffer for as long as a word's fade lasts.

**Orb linger is outcome-dependent.** 250ms on success (just enough to see the ring-pulse), 4500ms on failure (long enough to read the pill). One number for both would either be slow on the happy path or too fast to read on the unhappy path.

**Verification result downgrades but never upgrades.** A `.failed` from the cascade is final; verification only ever turns `.succeeded` into `.silentDrop`. If the cascade refused the paste outright, we don't second-guess it.
