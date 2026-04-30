# Inline corrections & speaker rename — design

**Status:** Approved 2026-04-30
**Surface:** Meeting recorder (`SessionDetailView`) — read-only transcript view
**Author:** Aaron, with Claude

## Why

The current "Teach…" button in the session footer opens a modal with two text fields (heard / meant). It works, but two things are wrong with it:

1. **The label "Teach…" is opaque.** Without context, no one knows what "Teach" does. The ellipsis was read as visual truncation, not as the macOS "opens-a-dialog" convention.
2. **The interaction is backwards.** A user noticing a transcription error already has the wrong word in front of them — making them retype it into a modal is friction. The natural mental model is "select the wrong text → fix it in place."

Separately: every transcript is labelled `Speaker 1`, `Speaker 2`, … which is fine for one-off review but useless for long-term archives. Users want to assign real names (Aaron / Sara / "the customer") and have those names render throughout the session.

This spec replaces the modal Teach flow with a select-and-fix toolbar, and adds click-to-rename on speaker labels.

## Scope

**In scope:**
- Floating "Fix" toolbar that appears above text selections in the transcript.
- Right-click "Suggest correction…" context menu item (keyboard-driven equivalent).
- Click-to-rename on `Speaker N:` labels with stored-text rewrite.
- Footer cleanup: remove `Teach…` button; rename `Save…` → `Save`.

**Out of scope (deliberate punts):**
- Cross-session voice-fingerprint matching ("once you've named Aaron, future recordings auto-detect him"). Real value, but it's a research-and-engineering chunk on its own — defer to a future version.
- Free-form transcript editing (typing over text without going through the Fix popover). Risks producing garbage corrections we can't tell apart from real transcription errors.
- Bulk correction tooling, correction history UI, undo of saved corrections.

## User-visible behaviour

### Footer (`SessionDetailView`)

Buttons left-to-right: **Copy**, **Save**, *(corrections badge)*, *(spacer)*, **Delete**.

The `Teach…` button and its modal `correctionSheet` are removed entirely. The "N corrections" badge stays where it is and now reflects the count from inline-Fix saves (same `CorrectionsStore` underneath — only the entry-point UI changes). `Save` keeps its `⌘S` shortcut and its tooltip.

### Inline "Fix" flow

1. User selects a span of text inside the transcript body.
2. A small floating pill appears immediately above the selection: a single **Fix** button with a `pencil.and.scribble` icon.
3. Clicking **Fix** opens a popover anchored to the pill containing:
   - The selected text rendered as a read-only "Heard:" line.
   - A `TextField` labelled *"What you actually said"*.
   - A scope `Picker`: `This session` (default) / `Everywhere`.
   - `Cancel` and `Save correction` buttons.
4. **Save correction** routes through `corrections.record(sessionId:originalText:correctedText:scope:source:)` with `source: .teaching` — same data path the modal used.
5. The toolbar dismisses on: click outside, Escape, scroll, selection collapse, or successful save.
6. **Right-click** on a selected span shows a `Suggest correction…` menu item that opens the same popover. Covers the keyboard-driven user.

**Default scope is `This session`** (the modal currently defaults to `.global`; we're flipping it). Lower stakes, fewer regrets if a user fires off a quick session-specific fix without thinking about scope.

### Speaker rename

1. Each `Speaker N:` label at the start of a transcript turn renders as a **clickable pill**: bold text, slightly tinted background, pointer cursor on hover, distinct from the body copy.
2. Clicking a pill opens a popover anchored to it:
   - `TextField` pre-filled with the current label (e.g. `Speaker 1`, or `Aaron` if previously renamed).
   - Helper text: *"Rename everywhere in this session"*.
   - `Cancel` / `Save`.
3. **Save** rewrites every `^<oldName>: ` occurrence in the stored `transcriptText` (line-anchored) to `<newName>: ` and persists via `SessionStore.save(_:)`.
4. **Empty input** is treated as Cancel — the rewrite is skipped and the popover closes. (Unlike title rename, there's no recoverable "auto" label to revert to once the original `Speaker N` has been overwritten in the transcript text.)
5. **Collision check:** if the new name matches another current speaker label in the same session, the popover shows an inline error and the Save button is disabled. (Without this, two speakers' turns merge with no recovery.)

For sessions where `speakerLabelsEnabled == false`, the transcript has no leading `Speaker N:` prefixes, no pills render, and the rename UX is silently absent. No code paths special-case this — the renderer just produces a single label-less turn.

## Architecture

### Storage model

The transcript stays a single `String` on `TranscriptSession.transcriptText`. No schema changes. Speaker rename is a **rewrite** of the stored text (option Y from the brainstorm), not a display-time mapping (option X was rejected).

Why rewrite over mapping:
- Simpler. No new field, no JSON migration, exports work unchanged.
- Anchored regex rewrite is safe — mid-sentence occurrences of a name aren't touched (see "Rename rewrite safety" below).
- The set of "current speaker labels in this session" is recoverable from the stored text alone (parse line-leading `[^:\n]+: ` prefixes), so we don't need separate state to track what's been renamed.

### New components

**`SelectableTranscriptView` (`Sources/Humdrum/SelectableTranscriptView.swift`)**
An `NSViewRepresentable` wrapping a read-only `NSTextView`. SwiftUI's `Text(.textSelection(.enabled))` doesn't expose selection range, which the floating toolbar needs.

Exposes:
- `Binding<NSRange?>` for current selection range
- A callback `(rect: CGRect, selectedString: String) -> Void` fired on selection change, with the selection's window-coordinate rect (for toolbar positioning) and the selected substring (for popover pre-fill)
- A second callback fired on selection collapse so the parent can dismiss the toolbar

Read-only — we are not making the transcript freely editable. That keeps "what counts as a correction" unambiguous: every saved correction came through the explicit Fix popover.

**`FixToolbar` (`Sources/Humdrum/FixToolbar.swift`)**
Two views in one file:
- `FixPill` — the floating pencil + "Fix" capsule that anchors above selection.
- `FixPopover` — the form view (Heard / Meant / scope / Save).

Both purely SwiftUI; FixPopover routes through an injected `CorrectionsStore` reference.

**`SpeakerLabelPill` (`Sources/Humdrum/SpeakerLabelPill.swift`)**
The clickable label pill plus the rename popover. Self-contained: takes `currentName: String`, `existingNames: [String]` (for collision check), and `onSave: (String) -> Void`. Doesn't know about `SessionStore` directly — the parent hands it the rename closure.

### Modified components

**`TranscriptSession` (`Sources/Humdrum/SessionStore.swift`)**

Add two helpers:

```swift
struct Turn { let label: String?; let body: String }

extension TranscriptSession {
    /// Splits transcriptText line-by-line into turns. A turn's `label` is
    /// the leading `Foo: ` if the line starts with `^[^:\n]+: `, else nil.
    /// Used by SessionDetailView's renderer.
    static func parseTurns(_ text: String) -> [Turn] { ... }

    /// Unique speaker labels in the order of their first appearance.
    /// Used for collision detection during rename.
    var speakerLabels: [String] { ... }
}
```

`parseTurns` and `speakerLabels` get unit tests (see Testing).

**`SessionDetailView.swift`**

Removed:
- `showTeachConfirmation` state, `beginTeach()`, `correctionSheet`, `correctionHeard`, `correctionMeant`, `correctionScope`, `showCorrectionSheet` state.
- The `Teach…` button.
- The ellipsis on `Save…`.

Added:
- A new computed `transcriptScroll` that builds a `LazyVStack` of `Turn`s. Each turn renders `SpeakerLabelPill` (when `label != nil`) followed by `SelectableTranscriptView` for the body.
- `@State private var fixSelection: FixSelection?` driving the floating toolbar.
- `private func renameSpeaker(from oldName: String, to newName: String)` that runs the anchored-line regex rewrite, validates collisions, and calls `store.save(_:)` with the updated session.
- `private func saveCorrection(heard:meant:scope:)` calling `corrections.record(...)` — same call site the old modal used, now invoked from the popover.

**`CorrectionsStore`** — no changes. The Fix popover hits the existing `record(sessionId:originalText:correctedText:scope:source:)` API.

**`DiarizationService`** — no changes.

**`TranscriptExporter`** — no changes; reads the (possibly renamed) `transcriptText` directly.

### Rename rewrite safety

The rename has to be anchored or it'll corrupt the transcript. Concrete plan:

```swift
let escaped = NSRegularExpression.escapedPattern(for: oldName)
let pattern = "(?m)^\(escaped): "
let regex = try NSRegularExpression(pattern: pattern)
let range = NSRange(transcriptText.startIndex..., in: transcriptText)
let rewritten = regex.stringByReplacingMatches(
    in: transcriptText,
    range: range,
    withTemplate: NSRegularExpression.escapedTemplate(for: newName) + ": "
)
```

Key properties:
- `(?m)^` = match at line starts only — mid-sentence "Aaron" stays untouched.
- `escapedPattern(for:)` handles old labels that contain regex metacharacters (e.g. `Speaker 1` has no metas, but a user-renamed `(Customer)` would).
- `escapedTemplate(for:)` handles new labels that contain `$` or `\` template metas.

### Selection across turn boundaries

Since each turn's body is its own `SelectableTranscriptView`, you can't select text that spans two speakers' turns in a single drag. This is acceptable and arguably desirable:

- Corrections almost always target a single speaker's words.
- Per-turn isolation means the pre-filled "Heard" line in the Fix popover never accidentally captures a stray `Speaker 2:` label.
- If users ever ask for cross-turn selection, we can revisit by collapsing to a single `NSTextView` with structured runs — but that's a much bigger change.

Cross-turn selection is also unsupported in most macOS chat/transcript apps (Messages, Slack), so the precedent is fine.

## Testing

**`TranscriptSessionTests` (new):**
- `parseTurns` round-trip: standard `Speaker 1: hi\nSpeaker 2: hey` → `[(Speaker 1, hi), (Speaker 2, hey)]`.
- `parseTurns` with no labels: a flat string with no `:` prefixes → one label-less turn.
- `parseTurns` with mid-line colons: `Speaker 1: meeting at 3:30` → label is `Speaker 1`, body is `meeting at 3:30` (only the first `:` after a leading non-`:`-or-`\n` prefix counts).
- `speakerLabels` order-of-first-appearance: `Speaker 2: a\nSpeaker 1: b\nSpeaker 2: c` → `["Speaker 2", "Speaker 1"]`.
- `renameSpeaker` anchored rewrite: confirm `^Aaron: ` is replaced everywhere but bare-word `Aaron` mid-sentence is not.
- `renameSpeaker` collision detection: renaming `Speaker 1` → `Speaker 2` when `Speaker 2` is already present surfaces an error and does not write.
- `renameSpeaker` empty input is a no-op: empty new name skips the rewrite entirely (the UI guard means it shouldn't reach `renameSpeaker` in the first place, but the function asserts on it as a defensive check).
- `renameSpeaker` regex-meta safety: rename a speaker labelled `(Customer)` to `Aaron` works without throwing.

**Manual smoke:**
- Rename Speaker 1 → Aaron. Confirm transcript visually updates and `speakerLabels == ["Aaron", "Speaker 2"]`.
- Rename Aaron → Bob. Confirm round-trips cleanly.
- Save a session, restart the app, reopen — confirm renames persisted.
- Export to .txt / .md / .rtf / .json — confirm renamed labels appear.
- Select a phrase mid-sentence, click Fix, save with default `This session` scope. Re-record the same phrase with the same wording and confirm the bias kicks in (existing CorrectionsStore behaviour).
- Right-click a selection, choose "Suggest correction…", save — confirm same flow as the floating toolbar.
- Sessions with `speakerLabelsEnabled == false` (no diarization): confirm no pills render and the Fix flow still works.

## Build sequence

Each step builds and is shippable independently. If a later step turns out gnarlier than expected, earlier steps are still wins on their own.

1. **Footer cleanup.** Remove `Teach…` button + `correctionSheet` + associated state from `SessionDetailView`. Rename `Save…` → `Save`. Build, smoke-test the existing flow.
2. **Turn parser + read-only speaker pills.** Add `parseTurns` and `speakerLabels` to `TranscriptSession`. Refactor `transcriptScroll` to a `LazyVStack` of turns rendering current speaker labels as styled-but-not-yet-clickable pills. Verify nothing visually regresses.
3. **Speaker rename popover.** Make pills clickable, add the rename popover, implement `renameSpeaker(from:to:)` with anchored-line rewrite + collision check. Add unit tests for `parseTurns`, `speakerLabels`, `renameSpeaker`.
4. **Selectable transcript wrapper.** Build `SelectableTranscriptView`. Replace each turn's body `Text` with the wrapper. Verify selection / copy / right-click all still work.
5. **Floating Fix toolbar + popover.** Build `FixToolbar`, wire it to the wrapper's selection-changed callback, route Save through `corrections.record(...)` with `scope: .session` default.
6. **Right-click "Suggest correction…" menu item.** Add the keyboard-driven door for the same flow.

## Risks & open questions

- **Popover repositioning during scroll.** SwiftUI's `.popover` re-anchors automatically; if it gets weird (e.g. floats off-screen during a scroll while open), fall back to dismissing on scroll.
- **`NSTextView` first-responder management.** Multiple text views per session detail view; the floating toolbar's button click must not steal first-responder away in a way that collapses the selection before we read it. Mitigation: capture the selected range/string at the moment the toolbar appears (in the wrapper's selection-changed callback), so the popover doesn't depend on the text view still having a live selection when it renders.
- **Existing Teach modal corrections in the wild.** Anyone running the current build has saved corrections via the modal. Those persist untouched in `CorrectionsStore`'s on-disk JSON — the new flow appends to the same store, no migration needed.
