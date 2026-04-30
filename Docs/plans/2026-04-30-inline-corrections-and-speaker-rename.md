# Inline Corrections & Speaker Rename — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Humdrum's modal "Teach…" correction flow with an inline floating "Fix" toolbar that appears on text selection, and add click-to-rename on `Speaker N:` labels (with anchored stored-text rewrite).

**Architecture:** Pure-logic helpers (`parseTurns`, label extraction, anchored rewrite) live in the existing `HumdrumCore` SPM target so they're testable from XCTest. UI surfaces (`NSTextView` wrapper, floating toolbar, label pill) live in the `Humdrum` app target. The transcript stays a single `String` on `TranscriptSession.transcriptText` — speaker rename is a regex-anchored rewrite, not a display-time mapping. Inline corrections route through the existing `CorrectionsStore.record(...)` API; only the entry-point UI changes.

**Tech Stack:** Swift 5.9+, SwiftUI on macOS 14+, AppKit (`NSTextView`, `NSViewRepresentable`), XCTest, `NSRegularExpression`. SPM target: `HumdrumCore` (pure logic), `Humdrum` (app), `HumdrumCoreTests` (XCTest).

**Reference:** Spec at `Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md`. All decisions (option B for selection toolbar, option Y for rename storage, no cross-session voice memory, default `This session` scope, no ellipsis on Save) are locked there.

---

## File Structure

**New (pure logic, in `HumdrumCore`):**
- `Sources/HumdrumCore/SpeakerLabels.swift` — `public enum SpeakerLabels` with `parseTurns(_:)`, `extractLabels(_:)`, `rename(text:from:to:)` static helpers.

**New (UI, in `Humdrum` app target):**
- `Sources/Humdrum/SelectableTranscriptView.swift` — `NSViewRepresentable` wrapping a read-only `NSTextView`. Surfaces selection range + window-coordinate rect via callbacks. Used per-turn for the body text.
- `Sources/Humdrum/FixToolbar.swift` — two SwiftUI views: `FixPill` (the floating capsule above selections) and `FixPopover` (the correction form: Heard / Meant / scope / Save).
- `Sources/Humdrum/SpeakerLabelPill.swift` — clickable label pill + rename popover (TextField + collision check + Save).

**New tests:**
- `Tests/HumdrumCoreTests/SpeakerLabelsTests.swift` — round-trips, ordering, anchored rewrite, regex-meta safety, collision detection.

**Modified:**
- `Sources/Humdrum/SessionStore.swift` — add `extension TranscriptSession` with `parseTurns` and `speakerLabels` delegating to `HumdrumCore.SpeakerLabels`.
- `Sources/Humdrum/SessionDetailView.swift` — remove `Teach…` button + `correctionSheet` + state; rename `Save…` → `Save`; replace `transcriptScroll`'s single `Text` with a `LazyVStack` of turns; wire up the floating toolbar; add `renameSpeaker(from:to:)`; add right-click "Suggest correction…" context menu.

**Untouched:**
- `CorrectionsStore.swift` — same API, new caller.
- `DiarizationService.swift`, `TranscriptExporter.swift` — unchanged.

---

## Task 1: Footer cleanup — remove Teach modal, drop Save ellipsis

**Files:**
- Modify: `Sources/Humdrum/SessionDetailView.swift`

**Why first:** Pure deletion. Verifies the build is healthy before we add new components. Visible UX win on its own (cleaner footer, less confusing label).

- [ ] **Step 1: Open `Sources/Humdrum/SessionDetailView.swift` and delete the Teach state vars**

Remove these `@State` declarations (currently lines ~30-34):

```swift
@State private var showCorrectionSheet: Bool = false
@State private var correctionHeard: String = ""
@State private var correctionMeant: String = ""
@State private var correctionScope: CorrectionScope = .global
@State private var showTeachConfirmation: Bool = false
```

- [ ] **Step 2: Remove the `.sheet(isPresented:)` modifier on the body**

In the `var body: some View` block, delete:

```swift
.sheet(isPresented: $showCorrectionSheet) {
    correctionSheet
}
```

- [ ] **Step 3: Remove the Teach button from `footerBar`**

Delete the `action(title: showTeachConfirmation ? ...)` block from `footerBar` (and its preceding comment). The `footerBar` should now contain: Copy, Save, the corrections badge, Spacer, Delete.

- [ ] **Step 4: Drop the ellipsis on Save**

In `footerBar`, change:

```swift
action(title: "Save…", systemImage: "square.and.arrow.down", run: save)
```

to:

```swift
action(title: "Save", systemImage: "square.and.arrow.down", run: save)
```

(`keyboardShortcut("s", modifiers: [.command])` and the `.help("Save as .txt or .md")` modifier stay.)

- [ ] **Step 5: Delete `beginTeach()`, `saveCorrection()`, and the `correctionSheet` computed view**

Delete the `beginTeach`, `saveCorrection`, and `correctionSheet` declarations (and their leading comments). Keep `sessionCorrections` — it's still feeding the badge and will be re-used by the Fix popover later.

- [ ] **Step 6: Build to confirm nothing else referenced the removed code**

Run: `swift build`
Expected: clean build, no errors.

- [ ] **Step 7: Smoke-test the existing Copy / Save / Delete flow**

Run the app (`./build-app.sh && open Humdrum.app` or via Xcode). Open any past session.
- Click Copy → confirm "Copied!" flash, paste somewhere to verify.
- Click Save → confirm save panel opens, save somewhere, verify the file was written.
- Confirm there is no Teach button in the footer.
- Confirm the Save button reads `Save` (no ellipsis).

- [ ] **Step 8: Commit**

```bash
git add Sources/Humdrum/SessionDetailView.swift
git commit -m "ui(session): remove Teach modal, drop Save ellipsis

Footer cleanup ahead of the inline-fix flow. No replacement entry point
yet — the floating Fix toolbar lands in a follow-up commit. Save loses
its HIG ellipsis per project preference.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 2: `SpeakerLabels` pure-logic helpers in HumdrumCore (TDD)

**Files:**
- Create: `Sources/HumdrumCore/SpeakerLabels.swift`
- Create: `Tests/HumdrumCoreTests/SpeakerLabelsTests.swift`

**Why this lives in `HumdrumCore`:** The test target only depends on `HumdrumCore`, not the app target. Putting the parsing/rewrite logic here makes it directly XCTest-able (the rest of `TranscriptSession` lives in the app target and isn't reachable from tests). The functions are pure — no MainActor, no AppKit, no Apple framework deps beyond `Foundation`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/HumdrumCoreTests/SpeakerLabelsTests.swift`:

```swift
import XCTest
@testable import HumdrumCore

final class SpeakerLabelsTests: XCTestCase {

    // MARK: parseTurns

    func testParseTurns_standardTwoSpeaker() {
        let text = "Speaker 1: hello there\nSpeaker 2: hi back"
        let turns = SpeakerLabels.parseTurns(text)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].label, "Speaker 1")
        XCTAssertEqual(turns[0].body, "hello there")
        XCTAssertEqual(turns[1].label, "Speaker 2")
        XCTAssertEqual(turns[1].body, "hi back")
    }

    func testParseTurns_noLabels() {
        let text = "just a flat transcript with no speaker prefixes"
        let turns = SpeakerLabels.parseTurns(text)
        XCTAssertEqual(turns.count, 1)
        XCTAssertNil(turns[0].label)
        XCTAssertEqual(turns[0].body, text)
    }

    func testParseTurns_midLineColons() {
        // Body contains a colon (e.g. "3:30") — only the first colon
        // separating the label from the body counts.
        let text = "Speaker 1: meeting at 3:30 today"
        let turns = SpeakerLabels.parseTurns(text)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].label, "Speaker 1")
        XCTAssertEqual(turns[0].body, "meeting at 3:30 today")
    }

    func testParseTurns_emptyString() {
        let turns = SpeakerLabels.parseTurns("")
        XCTAssertEqual(turns.count, 0)
    }

    func testParseTurns_blankLinesPreserved() {
        // Blank lines between turns shouldn't produce phantom turns.
        let text = "Speaker 1: hi\n\nSpeaker 2: hey"
        let turns = SpeakerLabels.parseTurns(text)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].label, "Speaker 1")
        XCTAssertEqual(turns[1].label, "Speaker 2")
    }

    func testParseTurns_renamedLabel() {
        let text = "Aaron: hi\nSara: hey"
        let turns = SpeakerLabels.parseTurns(text)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].label, "Aaron")
        XCTAssertEqual(turns[1].label, "Sara")
    }

    // MARK: extractLabels

    func testExtractLabels_orderOfFirstAppearance() {
        let text = "Speaker 2: a\nSpeaker 1: b\nSpeaker 2: c\nSpeaker 1: d"
        XCTAssertEqual(SpeakerLabels.extractLabels(text), ["Speaker 2", "Speaker 1"])
    }

    func testExtractLabels_empty() {
        XCTAssertEqual(SpeakerLabels.extractLabels(""), [])
    }

    func testExtractLabels_noLabels() {
        XCTAssertEqual(SpeakerLabels.extractLabels("flat text no labels"), [])
    }

    // MARK: rename

    func testRename_anchoredOnly() {
        // Mid-sentence "Aaron" should NOT be replaced.
        let before = "Aaron: hi\nSpeaker 2: nice to meet you, Aaron"
        let after = SpeakerLabels.rename(text: before, from: "Aaron", to: "Bob")
        XCTAssertEqual(after, "Bob: hi\nSpeaker 2: nice to meet you, Aaron")
    }

    func testRename_multipleOccurrencesAtLineStart() {
        let before = "Aaron: hi\nSpeaker 2: hello\nAaron: how are you"
        let after = SpeakerLabels.rename(text: before, from: "Aaron", to: "Bob")
        XCTAssertEqual(after, "Bob: hi\nSpeaker 2: hello\nBob: how are you")
    }

    func testRename_regexMetaInOldName() {
        // A label with a regex meta character must be escaped.
        let before = "(Customer): hi\n(Customer): again"
        let after = SpeakerLabels.rename(text: before, from: "(Customer)", to: "Aaron")
        XCTAssertEqual(after, "Aaron: hi\nAaron: again")
    }

    func testRename_templateMetaInNewName() {
        // A new name with a `$` would be a template meta — must be escaped.
        let before = "Speaker 1: hi"
        let after = SpeakerLabels.rename(text: before, from: "Speaker 1", to: "$boss")
        XCTAssertEqual(after, "$boss: hi")
    }

    func testRename_noMatch_returnsUnchanged() {
        let before = "Speaker 1: hi\nSpeaker 2: hey"
        let after = SpeakerLabels.rename(text: before, from: "Aaron", to: "Bob")
        XCTAssertEqual(after, before)
    }

    func testRename_firstLineLabel() {
        // The very first label (no preceding newline) must still match.
        let before = "Speaker 1: hi"
        let after = SpeakerLabels.rename(text: before, from: "Speaker 1", to: "Aaron")
        XCTAssertEqual(after, "Aaron: hi")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HumdrumCoreTests.SpeakerLabelsTests`
Expected: compilation failure ("cannot find 'SpeakerLabels' in scope") — that's the desired failing state.

- [ ] **Step 3: Create the implementation**

Create `Sources/HumdrumCore/SpeakerLabels.swift`:

```swift
import Foundation

/// Pure-logic helpers for working with the leading `Foo: ` speaker labels
/// at the start of each turn in a transcript.
///
/// The transcript is stored as a single `String` on `TranscriptSession`,
/// with one turn per line in the form `<label>: <body>`. These helpers
/// know how to parse that shape, list the unique labels, and do a safe
/// anchored rewrite for the speaker-rename UI.
///
/// All functions are pure (no Foundation date/locale dependencies, no
/// I/O), so they live in `HumdrumCore` where they're directly testable
/// from XCTest without the app host.
public enum SpeakerLabels {

    /// One turn in a transcript. `label` is `nil` when the line has no
    /// `^[^:\n]+: ` prefix (e.g. transcripts recorded with diarization
    /// disabled).
    public struct Turn: Equatable {
        public let label: String?
        public let body: String

        public init(label: String?, body: String) {
            self.label = label
            self.body = body
        }
    }

    /// Splits a transcript string into turns, line-by-line. A line with a
    /// `<label>: <body>` shape becomes a labelled turn; any other
    /// non-empty line becomes an unlabelled turn carrying the whole line
    /// as `body`. Blank lines are dropped — they're cosmetic in the
    /// stored text and shouldn't surface as phantom turns in the
    /// renderer.
    ///
    /// The label match is anchored to the start of the line and only
    /// consumes characters up to the first `:`. So `"Speaker 1: meeting
    /// at 3:30"` parses as label=`"Speaker 1"`, body=`"meeting at 3:30"`
    /// — only the first colon counts.
    public static func parseTurns(_ text: String) -> [Turn] {
        guard !text.isEmpty else { return [] }
        // Split on \n preserving empty subsequences so we don't drop
        // blank lines silently — but we *do* skip them when building
        // turns below.
        var turns: [Turn] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let (label, body) = splitLabel(line) {
                turns.append(Turn(label: label, body: body))
            } else {
                turns.append(Turn(label: nil, body: line))
            }
        }
        return turns
    }

    /// All unique labels appearing at the start of turns, in the order
    /// they first appear. Used by the rename popover for collision
    /// detection.
    public static func extractLabels(_ text: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for turn in parseTurns(text) {
            guard let label = turn.label, !seen.contains(label) else { continue }
            seen.insert(label)
            ordered.append(label)
        }
        return ordered
    }

    /// Returns `text` with every line-leading occurrence of `<oldName>: `
    /// rewritten to `<newName>: `. Mid-sentence occurrences of `oldName`
    /// are NOT touched (the match is anchored to start-of-line).
    ///
    /// Both `oldName` and `newName` are passed through the appropriate
    /// regex / template escaping, so labels containing regex metas
    /// (`(Customer)`) or template metas (`$boss`) round-trip safely.
    public static func rename(text: String, from oldName: String, to newName: String) -> String {
        guard !oldName.isEmpty, !newName.isEmpty else { return text }
        let escapedOld = NSRegularExpression.escapedPattern(for: oldName)
        let pattern = "(?m)^\(escapedOld): "
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let template = NSRegularExpression.escapedTemplate(for: newName) + ": "
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: template)
    }

    // MARK: Private

    /// Splits a single line into `(label, body)` if it matches
    /// `^[^:\n]+: `. Returns nil otherwise.
    private static func splitLabel(_ line: String) -> (String, String)? {
        // We don't use a regex here — `firstIndex(of: ":")` is faster
        // and the grammar is trivial.
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let label = String(line[..<colonIdx])
        // Must have at least one character before the colon, and the
        // character right after must be a space (matches our generation
        // pattern of `<label>: <body>`).
        guard !label.isEmpty else { return nil }
        let afterColon = line.index(after: colonIdx)
        guard afterColon < line.endIndex, line[afterColon] == " " else { return nil }
        let body = String(line[line.index(after: afterColon)...])
        return (label, body)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HumdrumCoreTests.SpeakerLabelsTests`
Expected: 14 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HumdrumCore/SpeakerLabels.swift Tests/HumdrumCoreTests/SpeakerLabelsTests.swift
git commit -m "core(speakers): add SpeakerLabels parse/extract/rename helpers

Pure-logic module in HumdrumCore so the parsing and anchored rename are
exercisable from XCTest. The app target's TranscriptSession will delegate
to these in the next commit. No UI changes yet.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 3: TranscriptSession delegates to SpeakerLabels

**Files:**
- Modify: `Sources/Humdrum/SessionStore.swift`

**Why now:** Wire the pure helpers up to the app's `TranscriptSession` model so the next UI tasks (turn-rendering, rename) have a clean property to read from.

- [ ] **Step 1: Add `speakerLabels` and `parseTurns` extension methods**

In `Sources/Humdrum/SessionStore.swift`, just below the `TranscriptSession` struct definition (and before the `// MARK: - Store` comment), add:

```swift
extension TranscriptSession {
    /// Unique speaker labels currently appearing at the start of turns,
    /// in order of first appearance. Drives collision detection in the
    /// speaker-rename popover and the rendering pass that decorates
    /// each turn with a clickable pill.
    var speakerLabels: [String] {
        SpeakerLabels.extractLabels(transcriptText)
    }

    /// Parsed view of `transcriptText` as a list of turns. Used by
    /// `SessionDetailView`'s renderer to lay out each turn as
    /// `[speaker pill] [body]`.
    var turns: [SpeakerLabels.Turn] {
        SpeakerLabels.parseTurns(transcriptText)
    }
}
```

(`SessionStore.swift` already does `import HumdrumCore` at the top, so `SpeakerLabels` resolves.)

- [ ] **Step 2: Build to confirm**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/Humdrum/SessionStore.swift
git commit -m "model(session): expose speakerLabels and turns on TranscriptSession

Thin delegations to HumdrumCore.SpeakerLabels so the upcoming rename UI
and turn-rendering both have a clean property to read.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 4: Render transcript as turns with read-only speaker pills

**Files:**
- Create: `Sources/Humdrum/SpeakerLabelPill.swift`
- Modify: `Sources/Humdrum/SessionDetailView.swift`

**Why before clickability:** Verify the new `LazyVStack` layout doesn't visually regress before adding interaction. If diarization-off sessions render wrong, we want to catch that here.

- [ ] **Step 1: Create `SpeakerLabelPill.swift` with a non-interactive pill view**

Create `Sources/Humdrum/SpeakerLabelPill.swift`:

```swift
import SwiftUI

/// Small pill rendering a `Speaker N: ` label (or a renamed equivalent).
/// In this first cut, the pill is purely visual. Click-to-rename lands
/// in a follow-up task — this view picks up the click handler then
/// without changes to its parent layout.
struct SpeakerLabelPill: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(AppTheme.accentSoft))
            .overlay(Capsule().stroke(AppTheme.accentBorder, lineWidth: 0.5))
    }
}
```

- [ ] **Step 2: Replace `transcriptScroll` in `SessionDetailView` with a turn-based renderer**

In `Sources/Humdrum/SessionDetailView.swift`, replace the existing `transcriptScroll` computed property:

```swift
private var transcriptScroll: some View {
    ScrollView {
        Text(session.transcriptText.isEmpty ? "(empty transcript)" : session.transcriptText)
            .font(.system(size: 14))
            .foregroundStyle(AppTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
    }
    .frame(maxHeight: .infinity)
}
```

with:

```swift
private var transcriptScroll: some View {
    ScrollView {
        if session.transcriptText.isEmpty {
            Text("(empty transcript)")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(session.turns.enumerated()), id: \.offset) { _, turn in
                    turnRow(turn)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .frame(maxHeight: .infinity)
}

@ViewBuilder
private func turnRow(_ turn: SpeakerLabels.Turn) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if let label = turn.label {
            SpeakerLabelPill(name: label)
        }
        Text(turn.body)
            .font(.system(size: 14))
            .foregroundStyle(AppTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Smoke-test layout**

Run the app. Open three different sessions:
1. A session with `Speaker 1` / `Speaker 2` labels (diarization on) — confirm each turn shows a pill above the body text.
2. A session with no speaker labels (diarization off) — confirm the body text renders without a pill, no extra blank space at the top.
3. An empty session (if one exists) — confirm "(empty transcript)" placeholder still renders.

Selection (`textSelection(.enabled)`) and Copy (`⌘C`) should still work on the body text.

- [ ] **Step 5: Commit**

```bash
git add Sources/Humdrum/SpeakerLabelPill.swift Sources/Humdrum/SessionDetailView.swift
git commit -m "ui(session): render transcript as turns with speaker pills (read-only)

Replaces the single Text() block with a LazyVStack of turns, each with a
non-clickable speaker pill atop its body text. Click-to-rename and the
inline Fix toolbar land in follow-up commits.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 5: Speaker pills become clickable; rename popover

**Files:**
- Modify: `Sources/Humdrum/SpeakerLabelPill.swift`
- Modify: `Sources/Humdrum/SessionDetailView.swift`

- [ ] **Step 1: Extend `SpeakerLabelPill` with click + popover**

Replace the contents of `Sources/Humdrum/SpeakerLabelPill.swift` with:

```swift
import SwiftUI

/// Clickable pill rendering a speaker label. Tapping opens a popover with
/// a rename TextField. The parent owns the rename closure — the pill
/// doesn't know about `SessionStore`.
struct SpeakerLabelPill: View {
    let name: String
    /// All other speaker labels currently in this session (excluding
    /// `name`). Used to block name collisions inline.
    let otherLabels: [String]
    let onRename: (String) -> Void

    @State private var showPopover = false
    @State private var draftName = ""

    var body: some View {
        Button(action: openPopover) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.accentSoft))
                .overlay(Capsule().stroke(AppTheme.accentBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Click to rename")
        .pointerStyle(.link)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            renamePopover
        }
    }

    private func openPopover() {
        draftName = name
        showPopover = true
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename speaker")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)

            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(commitIfValid)

            if let error = validationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.recording)
            } else {
                Text("Renames everywhere in this session.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { showPopover = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commitIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil || trimmedDraft == name)
            }
        }
        .padding(14)
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        let candidate = trimmedDraft
        if candidate.isEmpty { return "Name can't be blank." }
        // Disallow `:` and newlines — they'd break the line-anchored
        // label format the rename rewrite depends on.
        if candidate.contains(":") || candidate.contains("\n") {
            return "Name can't contain ‘:’ or line breaks."
        }
        if candidate != name && otherLabels.contains(candidate) {
            return "‘\(candidate)’ is already used by another speaker."
        }
        return nil
    }

    private func commitIfValid() {
        guard validationError == nil else { return }
        let candidate = trimmedDraft
        showPopover = false
        guard candidate != name else { return }
        onRename(candidate)
    }
}
```

(`pointerStyle(.link)` requires macOS 15+. If the build target is still macOS 14, swap to a no-op or use `.onHover` to set the cursor manually. **Check `Package.swift`'s `platforms`.** If 14, replace `.pointerStyle(.link)` with the macOS 14 fallback below before building.)

macOS 14 fallback (drop the `.pointerStyle(.link)` line, replace with):

```swift
.onHover { hovering in
    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
}
```

- [ ] **Step 2: Wire `onRename` in `SessionDetailView`**

In `Sources/Humdrum/SessionDetailView.swift`, update `turnRow(_:)`:

```swift
@ViewBuilder
private func turnRow(_ turn: SpeakerLabels.Turn) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if let label = turn.label {
            SpeakerLabelPill(
                name: label,
                otherLabels: session.speakerLabels.filter { $0 != label },
                onRename: { newName in renameSpeaker(from: label, to: newName) }
            )
        }
        Text(turn.body)
            .font(.system(size: 14))
            .foregroundStyle(AppTheme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

Add the `renameSpeaker` method to `SessionDetailView` (just above the `// MARK: Actions` comment):

```swift
private func renameSpeaker(from oldName: String, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    // Defensive — pill UI already enforces this, but keep the model
    // honest if a future caller skips validation.
    guard !trimmed.isEmpty,
          trimmed != oldName,
          !trimmed.contains(":"),
          !trimmed.contains("\n"),
          !session.speakerLabels.filter({ $0 != oldName }).contains(trimmed) else {
        return
    }
    var updated = session
    updated.transcriptText = SpeakerLabels.rename(
        text: session.transcriptText,
        from: oldName,
        to: trimmed
    )
    store.save(updated)
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build. If `pointerStyle` errors, apply the macOS 14 fallback from Step 1.

- [ ] **Step 4: Smoke-test rename**

Run the app. Open a session with at least two speakers.
1. Click "Speaker 1" → confirm popover appears with `Speaker 1` pre-filled.
2. Type "Aaron" → click Save → confirm transcript visually updates to "Aaron: …" wherever Speaker 1 spoke; "Speaker 2" turns are untouched.
3. Click "Aaron" again → rename to "Speaker 2" → confirm the popover shows the collision error and Save is disabled.
4. Click "Aaron" → clear the field → confirm Save is disabled with "Name can't be blank."
5. Quit the app, relaunch, reopen the session → confirm "Aaron" persisted.
6. Save the session as `.txt` → open in TextEdit → confirm "Aaron:" appears (not "Speaker 1:").
7. Test on a session with no speaker labels (diarization-off) → confirm no pills render, no rename UI exposed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Humdrum/SpeakerLabelPill.swift Sources/Humdrum/SessionDetailView.swift
git commit -m "ui(session): click speaker label to rename

Pill becomes clickable, opens a popover with collision detection and
inline validation. Rename rewrites stored transcriptText via the
anchored-line regex in SpeakerLabels.rename, then persists through
SessionStore.save. Empty / blank / colliding names are blocked at the
UI before they reach the model.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 6: `SelectableTranscriptView` — read-only NSTextView wrapper

**Files:**
- Create: `Sources/Humdrum/SelectableTranscriptView.swift`
- Modify: `Sources/Humdrum/SessionDetailView.swift`

**Why a custom NSViewRepresentable:** SwiftUI's `Text(.textSelection(.enabled))` doesn't expose the current selection range or its on-screen rect. Both are needed for the floating Fix toolbar. The wrapper is read-only — we still don't allow free-form editing.

- [ ] **Step 1: Create the wrapper**

Create `Sources/Humdrum/SelectableTranscriptView.swift`:

```swift
import SwiftUI
import AppKit

/// Read-only `NSTextView`-backed text view that surfaces selection state
/// to SwiftUI. Used per-turn so the floating Fix toolbar knows what was
/// selected and where to anchor its pill.
///
/// Why not `Text(.textSelection(.enabled))`: SwiftUI's selection APIs
/// don't expose selection range or rect. The toolbar needs both — the
/// rect to position the pill above the selection, and the substring to
/// pre-fill the correction popover's "Heard:" line.
struct SelectableTranscriptView: NSViewRepresentable {

    /// Snapshot of a current text selection: the substring and its rect
    /// in window coordinates (origin at top-left, AppKit-flipped).
    struct Selection: Equatable {
        let text: String
        let rectInWindow: CGRect
    }

    let text: String
    let onSelectionChange: (Selection?) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor(AppTheme.textPrimary)
        textView.string = text
        textView.delegate = context.coordinator
        // Match the surrounding LazyVStack — no internal scrolling, the
        // outer ScrollView does the work.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.onSelectionChange = onSelectionChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: (Selection?) -> Void

        init(onSelectionChange: @escaping (Selection?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  let nsString = textView.string as NSString?,
                  range.location + range.length <= nsString.length else {
                onSelectionChange(nil)
                return
            }
            let selectedString = nsString.substring(with: range)
            // Convert text-container rect → window coordinates so the
            // SwiftUI floating pill can position itself above it.
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                onSelectionChange(nil)
                return
            }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rectInTextContainer = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let rectInTextView = rectInTextContainer.offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
            let rectInWindow = textView.convert(rectInTextView, to: nil)
            onSelectionChange(Selection(text: selectedString, rectInWindow: rectInWindow))
        }
    }
}
```

- [ ] **Step 2: Swap turn body `Text` for the wrapper**

In `Sources/Humdrum/SessionDetailView.swift`, update `turnRow(_:)`:

```swift
@ViewBuilder
private func turnRow(_ turn: SpeakerLabels.Turn) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if let label = turn.label {
            SpeakerLabelPill(
                name: label,
                otherLabels: session.speakerLabels.filter { $0 != label },
                onRename: { newName in renameSpeaker(from: label, to: newName) }
            )
        }
        SelectableTranscriptView(text: turn.body) { _ in
            // Selection plumbed for real in Task 7.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // NSTextView doesn't intrinsic-content-size by default; pin a
        // sensible min height so empty turns don't collapse to 0.
        .frame(minHeight: 22)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Smoke-test**

Run the app, open a session with multiple speakers.
1. Drag-select text within a single turn → confirm selection highlight appears.
2. `⌘C` → confirm the selection copies.
3. Right-click the selection → confirm AppKit's default "Copy / Look Up / …" menu still appears.
4. Try to drag-select across two turns → confirm selection doesn't span turn boundaries (each turn is its own NSTextView; this is intended).
5. Scroll the transcript with the selection still active → confirm scrolling is smooth (the outer ScrollView is doing the work).

- [ ] **Step 5: Commit**

```bash
git add Sources/Humdrum/SelectableTranscriptView.swift Sources/Humdrum/SessionDetailView.swift
git commit -m "ui(session): wrap turn bodies in NSTextView for selection plumbing

Replaces the per-turn Text() with a read-only NSViewRepresentable that
exposes selection range + window rect. Floating Fix toolbar wires into
the selection callback in the next commit.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 7: Floating Fix toolbar + correction popover

**Files:**
- Create: `Sources/Humdrum/FixToolbar.swift`
- Modify: `Sources/Humdrum/SessionDetailView.swift`

- [ ] **Step 1: Create `FixToolbar.swift` (pill + popover)**

Create `Sources/Humdrum/FixToolbar.swift`:

```swift
import SwiftUI
import AppKit

/// State carried between the selection callback and the floating pill /
/// popover. Captured at the moment the user makes a selection so the
/// popover doesn't depend on the NSTextView still having a live
/// selection when it renders.
struct FixSelection: Equatable {
    let heard: String
    let rectInWindow: CGRect
}

/// Small floating capsule that appears above a text selection. Tapping
/// it surfaces the correction popover.
struct FixPill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 11, weight: .semibold))
                Text("Fix")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(AppTheme.accent)
            )
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

/// Correction popover. Heard line is read-only, Meant is editable, scope
/// defaults to `.session` (project preference — see spec).
struct FixPopover: View {
    let heard: String
    let onSave: (String, CorrectionScope) -> Void
    let onCancel: () -> Void

    @State private var meant: String = ""
    @State private var scope: CorrectionScope = .session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Heard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                Text(heard)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: 320, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What you actually said")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("", text: $meant, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .frame(width: 320)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Apply this correction to")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                Picker("", selection: $scope) {
                    ForEach(CorrectionScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save correction") {
                    onSave(meant, scope)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    meant.trimmingCharacters(in: .whitespaces).isEmpty ||
                    meant.trimmingCharacters(in: .whitespaces) == heard.trimmingCharacters(in: .whitespaces)
                )
            }
        }
        .padding(16)
    }
}
```

- [ ] **Step 2: Wire selection plumbing into `SessionDetailView`**

In `Sources/Humdrum/SessionDetailView.swift`:

Add the new state vars near the existing `@State` declarations:

```swift
@State private var fixSelection: FixSelection?
@State private var showFixPopover: Bool = false
```

Update `turnRow(_:)` to actually pipe selection through:

```swift
@ViewBuilder
private func turnRow(_ turn: SpeakerLabels.Turn) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if let label = turn.label {
            SpeakerLabelPill(
                name: label,
                otherLabels: session.speakerLabels.filter { $0 != label },
                onRename: { newName in renameSpeaker(from: label, to: newName) }
            )
        }
        SelectableTranscriptView(text: turn.body) { selection in
            handleSelectionChange(selection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 22)
    }
}

private func handleSelectionChange(_ selection: SelectableTranscriptView.Selection?) {
    if let selection {
        fixSelection = FixSelection(
            heard: selection.text,
            rectInWindow: selection.rectInWindow
        )
    } else if !showFixPopover {
        // Don't clobber the selection while the popover is open — the
        // user has likely clicked into the TextField, which collapses
        // the NSTextView's selection.
        fixSelection = nil
    }
}
```

Add the floating pill overlay to the main `body`. Replace the existing `body` block:

```swift
var body: some View {
    ZStack {
        AppTheme.background.ignoresSafeArea()

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.border)
            metaRow
            Divider().overlay(AppTheme.border)
            transcriptScroll
            Divider().overlay(AppTheme.border)
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        // Floating Fix pill anchored above the current selection, in
        // window coordinates. We render it in a top-aligned overlay so
        // its position is independent of the LazyVStack's layout. Note
        // we keep the pill visible while the popover is open — the
        // popover anchors to the pill, so removing it would orphan the
        // popover.
        if let selection = fixSelection {
            fixPillOverlay(selection)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@ViewBuilder
private func fixPillOverlay(_ selection: FixSelection) -> some View {
    GeometryReader { proxy in
        // The selection rect is in window coordinates; convert to the
        // ZStack's local space by subtracting the ZStack's window frame
        // origin.
        let localFrame = proxy.frame(in: .global)
        let pillSize = CGSize(width: 60, height: 26)
        // `position` centres the view on the given point, so use
        // selection-rect midX directly. Float the pill ~6pt above the
        // selection's top edge.
        let centerX = selection.rectInWindow.midX - localFrame.minX
        let centerY = selection.rectInWindow.minY - localFrame.minY - pillSize.height / 2 - 6
        FixPill { showFixPopover = true }
            .frame(width: pillSize.width, height: pillSize.height)
            .position(x: centerX, y: centerY)
            .popover(isPresented: $showFixPopover, arrowEdge: .top) {
                FixPopover(
                    heard: selection.heard,
                    onSave: { meant, scope in
                        saveCorrection(heard: selection.heard, meant: meant, scope: scope)
                    },
                    onCancel: {
                        showFixPopover = false
                        fixSelection = nil
                    }
                )
            }
    }
}
```

Add the `saveCorrection` helper just above `// MARK: Actions`:

```swift
private func saveCorrection(heard: String, meant: String, scope: CorrectionScope) {
    _ = corrections.record(
        sessionId: session.id,
        originalText: heard,
        correctedText: meant,
        scope: scope,
        source: .teaching
    )
    showFixPopover = false
    fixSelection = nil
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Smoke-test the Fix flow**

Run the app, open a session.
1. Select a phrase inside one speaker's turn → confirm a small "Fix" pill appears just above the selection.
2. Click the pill → confirm the popover opens with the selected text in the "Heard" line and the scope set to `This recording only`.
3. Type a corrected phrase in "What you actually said" → confirm Save is enabled.
4. Click Save → confirm the popover closes and the corrections badge in the footer increments by one.
5. Quit + relaunch → reopen the session → confirm the badge count persists (the corrections file got written).
6. Test cancellation: select text → click Fix → click Cancel → confirm popover closes, no correction saved.
7. Test selection collapse: select text → click somewhere else in the transcript → confirm pill disappears.
8. Test no-op save: select "hello" → click Fix → leave Meant identical to Heard → confirm Save is disabled.

- [ ] **Step 5: Commit**

```bash
git add Sources/Humdrum/FixToolbar.swift Sources/Humdrum/SessionDetailView.swift
git commit -m "ui(session): floating Fix toolbar replaces Teach modal

Selecting transcript text surfaces a small Fix pill anchored above the
selection. Clicking it opens a popover with the heard text pre-filled,
a Meant TextField, and a scope picker (defaults to This recording only,
per spec). Saved corrections route through the existing CorrectionsStore
API — same data, new entry point.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 8: Right-click "Suggest correction…" context menu

**Files:**
- Modify: `Sources/Humdrum/SelectableTranscriptView.swift`
- Modify: `Sources/Humdrum/SessionDetailView.swift`

**Why:** Discoverability backstop for keyboard-driven users who select with `⇧⌥→` and never see the floating pill.

- [ ] **Step 1: Add a menu callback to `SelectableTranscriptView`**

In `Sources/Humdrum/SelectableTranscriptView.swift`, extend the wrapper to accept an additional callback for "user wants to fix this selection." The cleanest plumbing is to add a `NSMenuItem` to the text view's menu via the delegate:

Replace the `Coordinator` class with:

```swift
final class Coordinator: NSObject, NSTextViewDelegate {
    var onSelectionChange: (Selection?) -> Void
    var onSuggestCorrection: (Selection) -> Void

    init(
        onSelectionChange: @escaping (Selection?) -> Void,
        onSuggestCorrection: @escaping (Selection) -> Void
    ) {
        self.onSelectionChange = onSelectionChange
        self.onSuggestCorrection = onSuggestCorrection
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            onSelectionChange(nil)
            return
        }
        if let snapshot = makeSelection(from: textView, range: range) {
            onSelectionChange(snapshot)
        } else {
            onSelectionChange(nil)
        }
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let range = view.selectedRange()
        guard range.length > 0,
              let snapshot = makeSelection(from: view, range: range) else {
            return menu
        }
        let item = NSMenuItem(
            title: "Suggest correction…",
            action: #selector(suggestCorrection(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = snapshot
        menu.insertItem(item, at: 0)
        menu.insertItem(NSMenuItem.separator(), at: 1)
        return menu
    }

    @objc private func suggestCorrection(_ sender: NSMenuItem) {
        guard let snapshot = sender.representedObject as? Selection else { return }
        onSuggestCorrection(snapshot)
    }

    private func makeSelection(from textView: NSTextView, range: NSRange) -> Selection? {
        let nsString = textView.string as NSString
        guard range.location + range.length <= nsString.length else { return nil }
        let selectedString = nsString.substring(with: range)
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rectInTextContainer = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let rectInTextView = rectInTextContainer.offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
        let rectInWindow = textView.convert(rectInTextView, to: nil)
        return Selection(text: selectedString, rectInWindow: rectInWindow)
    }
}
```

Update the wrapper's properties to include the new callback:

```swift
let text: String
let onSelectionChange: (Selection?) -> Void
let onSuggestCorrection: (Selection) -> Void

func makeCoordinator() -> Coordinator {
    Coordinator(
        onSelectionChange: onSelectionChange,
        onSuggestCorrection: onSuggestCorrection
    )
}

func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    if textView.string != text {
        textView.string = text
    }
    context.coordinator.onSelectionChange = onSelectionChange
    context.coordinator.onSuggestCorrection = onSuggestCorrection
}
```

- [ ] **Step 2: Wire the new callback in `SessionDetailView.turnRow`**

```swift
SelectableTranscriptView(
    text: turn.body,
    onSelectionChange: { selection in handleSelectionChange(selection) },
    onSuggestCorrection: { selection in
        fixSelection = FixSelection(heard: selection.text, rectInWindow: selection.rectInWindow)
        showFixPopover = true
    }
)
.frame(maxWidth: .infinity, alignment: .leading)
.frame(minHeight: 22)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Smoke-test**

Run the app, open a session.
1. Drag-select a phrase, then right-click → confirm "Suggest correction…" appears at the top of the menu (above the standard AppKit items).
2. Click "Suggest correction…" → confirm the same Fix popover opens, pre-filled with the selection.
3. Save a correction → confirm it lands in `CorrectionsStore` and the badge increments.
4. Confirm the floating pill flow still works (Task 7 didn't regress).
5. Right-click without a selection → confirm "Suggest correction…" does NOT appear (only the default AppKit menu).

- [ ] **Step 5: Commit**

```bash
git add Sources/Humdrum/SelectableTranscriptView.swift Sources/Humdrum/SessionDetailView.swift
git commit -m "ui(session): right-click ‘Suggest correction…’ menu item

Backstop entry point for keyboard-driven users who select with arrow
keys and don't trigger the floating Fix pill. Routes through the same
popover as the pill — no duplicate copy-path.

Refs: Docs/specs/2026-04-30-inline-corrections-and-speaker-rename-design.md"
```

---

## Task 9: Final sweep & manual end-to-end

**Files:** none (validation only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all `HumdrumCoreTests` pass, including the new `SpeakerLabelsTests`.

- [ ] **Step 2: Build a release-style app bundle**

Run: `./build-app.sh`
Expected: `Humdrum.app` builds and signs cleanly.

- [ ] **Step 3: End-to-end manual smoke**

Open `Humdrum.app`. Either record a fresh diarized session (≥2 speakers) or open an existing one.

| Scenario | Expected |
|---|---|
| Footer shows Copy / Save / *(badge)* / Delete; no Teach button | ✓ |
| Save label has no ellipsis | ✓ |
| Click `Speaker 1` → rename to `Aaron` → persists across relaunch | ✓ |
| Try to rename `Aaron` → `Speaker 2` (collision) | Save disabled, error visible |
| Try to rename to `bad:name` (colon) | Save disabled, error visible |
| Select text → Fix pill appears above selection | ✓ |
| Click Fix → popover with Heard pre-filled, scope = This recording only | ✓ |
| Save correction with empty Meant | Save disabled |
| Save correction matching Heard | Save disabled |
| Save valid correction → badge count increments | ✓ |
| Right-click selection → "Suggest correction…" at top | ✓ |
| Diarization-off session: no pills, Fix flow still works on body | ✓ |
| Export renamed session as .txt → file shows "Aaron:" prefixes | ✓ |

- [ ] **Step 4: Final commit (if any tweaks were needed)**

If the smoke test surfaced anything (typos, layout glitches), fix and commit. Otherwise skip.

- [ ] **Step 5: Push to main**

```bash
git push origin main
```

(No release cut yet — per the spec, this rides into the next normal version bump. The spec's risks/open-questions section flagged popover-during-scroll repositioning; if it surfaces in real use, file as a follow-up rather than blocking.)

---

## Summary

By the end of Task 9:

- `Teach…` modal is gone; corrections come from in-place selection via the Fix pill or right-click menu.
- Speaker labels are clickable; renames anchored to line starts so mid-sentence text is never corrupted.
- All pure-logic helpers live in `HumdrumCore` and are unit-tested.
- `CorrectionsStore`, `DiarizationService`, and `TranscriptExporter` are untouched — same data flow, new entry point.

Risks tracked in the spec (popover during scroll, NSTextView first-responder dance) carried over into the smoke-test checklist; nothing in the implementation forecloses fixing them later.
