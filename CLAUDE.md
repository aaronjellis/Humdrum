# MeetingScribe / Humdrum — Claude project notes

Things this Claude session should know before touching the codebase. Edit ruthlessly: when Claude makes a mistake, add the correction here so the next session inherits it.

## What this is

Humdrum is the Mac app project (binary name: `Humdrum`, target: `Sources/Humdrum/`). MeetingScribe is the umbrella name for the meeting-transcription product. Pure-logic code lives in `Sources/HumdrumCore/` so it's reachable by tests under `Tests/HumdrumCoreTests/`. Mac-only; deployment target is current macOS.

Build via `./build-app.sh` (release) or `swift build` / `swift test` (CI-style). The Linux sandbox **cannot** compile macOS/SwiftUI/WhisperKit targets — never claim a build is "verified" from inside the bash sandbox. Tests for the pure-logic target *can* run headless.

## Module placement rules

- Pure-logic code (no UI, no Apple-framework UI deps, no platform sensors) goes in `Sources/HumdrumCore/`. It must be `public` to be reachable from the app target.
- App-only code (SwiftUI views, AppKit hooks, recording, hotkeys) stays in `Sources/Humdrum/`.
- When moving pure logic from app → core, the app target needs `import HumdrumCore`. Don't leave duplicate copies — delete the app-target version when you move it.
- `FuzzyMatcher` lives in `HumdrumCore`. Tests in `Tests/HumdrumCoreTests/FuzzyMatcherTests.swift`.

## Carbon / CoreFoundation interop

When calling Carbon APIs (`InstallEventHandler`, `RegisterEventHotKey`, etc.) from Swift:

- Look up the current Swift signature in the SDK before writing the call site. Don't infer parameter types from memory — recent SDKs bind size/count parameters as `Int`, not `UInt32`. Casting `UInt32(buffer.count)` for `InstallEventHandler` is wrong; pass `buffer.count` raw.
- For a Swift `Array` passed to a C function expecting a contiguous pointer, use `array.withUnsafeBufferPointer { buf in ... buf.baseAddress, buf.count ... }`. Never `&array` — that yields the storage address of the Array struct, not the element buffer. `&singleValue` works for a scalar; `&array` does not.

## Push-to-talk and global hotkeys

- Use Carbon's `RegisterEventHotKey` (with both `kEventHotKeyPressed` and `kEventHotKeyReleased`) for PTT-style press-and-hold patterns. NSEvent global monitors leak the keystroke to the focused field, which causes the "spaces leaking into focused input" symptom.
- Keep a small *local* NSEvent monitor as a complementary swallow for the case where Humdrum's own window is focused.
- TCC / Accessibility grants are keyed on binary signature. After a rebuild, the grant may invalidate and `PasteCascade.decide` will return `.noAccessibility` silently. Surface this on the orb (red/yellow pill) rather than failing in silence.

## Transcription pipeline thresholds

These were tuned from production bugs. Don't revert them without evidence.

- `CommitThresholds.meeting.maxSegmentSeconds` = **12** (was 18; 18 caused tail-audio drops on stop in continuous-speech sessions).
- Tail transcribe deadline = **30s** (was 10s; 10s silently dropped tail audio).
- `runFinalizeOffMain` is `fileprivate` (not `private`) because its return type `FinalizeResult` is `fileprivate`. Both must change visibility together if either does.
- The finalize path captures `hypothesisText` into `capturedHypothesis` *before* resetting live state, so on tail-transcribe failure or timeout the most recent live partial is sanitized and committed as the tail. Don't move the capture later in `stop()`.

## FuzzyMatcher invariants

The matcher uses three tiers with hard score floors that guarantee monotonic ranking. Any change to a tier base must preserve the invariant `min(tier_N) > max(tier_N+1)`.

- Substring tier base: ≥ 1000 (prefix > word-boundary > middle).
- Subsequence tier base: ≥ 500.
- Typo tier (Levenshtein ≤ 2): base 100.

If you change tier bases, run the existing ranking test that asserts substring beats subsequence beats typo. The original implementation got this wrong and required a fix — don't repeat it.

Multi-word queries split on whitespace and require every token to hit. Fuzzy applies to titles only; transcripts use plain case-insensitive substring (Levenshtein over a 10k-word transcript is too noisy and too slow).

## Swift language gotchas in this package

- Bare-slash regex literals (`/.../`) do **not** compile here — the package isn't in Swift 6 language mode and `BareSlashRegexLiterals` isn't enabled. Use extended delimiters: `#/.../#`.
- `NoiseSanitizer` (HumdrumCore) is the single source of truth for hallucination filtering; `TranscriptionManager.sanitize` / `sanitizeStatic` are thin delegates. Never re-inline the banned-phrase list in the app target — it drifted into three copies once already.

## Git operations

The bash sandbox cannot write to the user's `.git/` directory and will leave a stale `index.lock`. **Never run `git add`, `git commit`, `git push`, `git rebase`, etc. from the sandbox.** Always return staging and commit instructions as a copy-pasteable block for the user's terminal. Writing the commit message to `/tmp/...` from the sandbox is fine; the actual `git commit -F /tmp/msg` runs locally.

## When something goes wrong

If Claude does something incorrectly in this codebase, add a one-line correction to this file before moving on. The point is to compound — every mistake should make the next session smarter, not the same.
