# Mutter paste reliability — research & recommendation

**Date:** 2026-04-25
**Author:** Aaron (with Claude)
**Status:** Recommendation pending review

## Problem

For longer spoken sentences, Mutter pastes **nothing at all** into the focused field. The symptom reproduces across every target — Electron, browsers, Cocoa, native — which rules out app-specific filtering and points the finger at our own paste pipeline.

Short utterances (one or two committed chunks) generally work. The failure scales with how many Whisper commits fire during a single dictation.

## What Mutter does today

`DictationCoordinator.handleTextUpdate` is wired to `TranscriptionManager.$confirmedText` via Combine. Every time a Whisper commit lands, the coordinator computes a string delta against the running `pastedText` cursor and calls `PasteHelper.paste(delta)` (`Sources/Humdrum/DictationCoordinator.swift:354–358, 470–495`).

`PasteHelper.paste` runs the clipboard cascade:

1. Snapshot `NSPasteboard.general`.
2. `setString(text)`.
3. Sleep 15ms so pasteboard-change observers settle.
4. Synthesize a four-event `cmd-down / V-down / V-up / cmd-up` sequence on `cghidEventTap`.
5. **Schedule a clipboard restore 500ms later** via `DispatchQueue.main.asyncAfter` (`Sources/Humdrum/PasteHelper.swift:243–295`).

So a single dictation that emits N Whisper commits produces **N independent clipboard write / ⌘V / 500ms-restore cycles, all in flight concurrently**. With dictation thresholds set to `minCommitSeconds: 1.2, maxSegmentSeconds: 7.0, tailSilenceSeconds: 0.5` (`TranscriptionManager.swift:115–119`), a 15-second monologue fires roughly 3–5 commits — all of them within the same 500ms restore window of the previous chunk.

## What every competing tool does

I surveyed the five tools with non-trivial macOS dictation share. The pattern is unanimous:

### Wispr Flow

Clipboard + ⌘V, with ~500ms restore. The behavior we already match. **But** their changelog explicitly notes that they had a bug where dictated text got inserted multiple times in slower apps (Google Docs, Gmail, Android editors) and they fixed it by going to **"text is now committed exactly once per dictation."** This is essentially the bug we're hitting, and they shipped a pivot to fix it. The Flow Bar shows real-time streaming transcription as visual feedback, but the actual paste into the focused field is a single ⌘V at end-of-utterance.

If insertion fails, they fall back to clipboard-only and surface a "click to paste" notification so the dictation is never lost.

### Superwhisper

Clipboard + ⌘V on dictation completion. Keystroke synthesis is a behind-a-toggle advanced fallback for apps that block paste, and even then it's US-QWERTY-only. Restore window is 3 seconds (much longer than ours), and there's a separate "preserve clipboard" toggle. Recording is full-utterance: speak → release → paste-once.

### VoiceInk (open source)

Same model. The paste path is a single call, `CursorPaster.pasteAtCursor(textToPaste + " ")`, fired once after transcription completes. They added CJK input-method handling — temporarily switch to ABC before ⌘V, restore after — but the basic shape is record → transcribe → paste-once.

### Aqua Voice

Has both an "Instant Mode" (full utterance, paste once) and a "Streaming Mode" that shows live transcription. Their docs are explicit that streaming output is for **review and edit before paste** — the user can format/correct in the overlay, and paste still happens once when they confirm. The 9to5Mac and YC profiles describe ~450–850ms typical latency end-to-end, again as a single insertion event.

### Talon Voice

Different paradigm — it's a hybrid command/dictation system aimed at accessibility power users, posts unicode keystroke events directly into target apps, and isn't really comparable to a Whisper-style dictation app. Worth noting only because it's the one tool that does post-as-you-go, and it's done via keystroke synthesis rather than clipboard. We already have keystroke synthesis as a tail fallback in `RealPasteBackend.insertViaKeystrokes`, so this isn't a new path to add — but Talon's model isn't a useful template for Mutter.

### Summary

| Tool          | Insertion path        | Cadence              | Restore window |
|---------------|-----------------------|----------------------|----------------|
| Wispr Flow    | Clipboard + ⌘V        | **Once per dictation** | ~500ms         |
| Superwhisper  | Clipboard + ⌘V        | **Once per dictation** | 3s              |
| VoiceInk      | Clipboard + ⌘V        | **Once per dictation** | (unknown, similar) |
| Aqua Voice    | Clipboard + ⌘V        | **Once per dictation** | (unknown)       |
| Talon         | Keystroke synthesis   | Streaming (different paradigm) | n/a    |
| **Mutter (current)** | **Clipboard + ⌘V** | **N pastes per dictation** | **500ms** |

Mutter is the only tool in the field doing a clipboard-paste-per-Whisper-commit, and the one tool that ever shipped that model (Wispr Flow before 1.5.2) explicitly retreated from it because of the same class of bug we're hitting.

## Why long sentences specifically lose everything

Once N pastes are concurrent, the failure mode is mechanical. The 500ms restore queued by paste-1 fires *while* paste-2's `setString` has already happened and paste-2's ⌘V is sitting in the receiving app's input queue. A common Electron / Chromium pattern is to lazy-read `NSPasteboard.general` from a renderer thread several hundred milliseconds after the synthesized ⌘V arrives. The race:

```
t=0     paste-1: setString("chunk-1"). schedule restore at t=500.
t=15    paste-1: post ⌘V. Receiver queues a paste event.
t=300   paste-2: setString("chunk-2"). schedule restore at t=800.
t=315   paste-2: post ⌘V. Receiver queues another paste event.
t=500   paste-1's restore fires. Pasteboard ← user's ORIGINAL contents.
t=520   Receiver finally reads pasteboard for paste-1's ⌘V → reads ORIGINAL. Drops or pastes the wrong thing.
t=540   Receiver reads pasteboard for paste-2's ⌘V → reads ORIGINAL. Same again.
t=600   paste-3: setString("chunk-3"). saved snapshot = ORIGINAL. (because t=500 restore already ran)
... etc.
```

The longer the dictation, the more layered restores compete for the pasteboard, and the higher the probability that *every* receive lands on the restored content rather than the chunk we intended. "Nothing pastes" is exactly what the receiver sees when its lazy-read consistently falls on the restored window — and once it falls behind, it stays behind.

A secondary contributor: each paste call serializes through the `@MainActor`, but the 500ms `DispatchQueue.main.asyncAfter` restore does *not* serialize against the next call's `setString`. The save/restore is fundamentally not atomic with respect to other clients' reads.

This is the most defensible mechanism given the Electron evidence. The "even native Cocoa apps fail" data point is harder to explain on lazy-read alone — Cocoa's pasteboard read is typically synchronous to the ⌘V event handler — and may indicate a separate contributor (modifier-flag drift across overlapping cmd-down/cmd-up sequences, or pasteboard `changeCount` thrash defeating receivers that key off it). The good news: the recommendation below eliminates *every* concurrency-shaped failure mode by removing the concurrency, so the precise mechanism doesn't need to be nailed down before we ship the fix.

## Recommendation: pivot to commit-once

Match the rest of the field. Concretely:

1. **Remove the per-commit paste path.** Delete (or gate behind a debug flag) `handleTextUpdate` → `PasteHelper.paste` and the `commitsSink` subscription on `confirmedText`.
2. **Keep the orb overlay's live preview.** The user already sees the visualizer; we can additionally surface the running `confirmedText + " " + hypothesisText` inside or beside the orb so they have the same "I see my words flowing" feedback that Wispr Flow's bar gives. This is purely a UI render; it does not paste anything.
3. **Paste exactly once on stop.** When `stop()` fires (hotkey tap, silence timeout, or no-speech timeout), wait for `manager.pendingFinalize` to land, then call `PasteHelper.paste(finalSnapshot.transcriptText)` a single time. Drop the `pastedText` cursor and `computeDelta` machinery — they become dead code.
4. **Keep clipboard + ⌘V as the path.** It's the right choice; the issue isn't the strategy, it's the cadence.
5. **Lengthen the restore window to ~2–3 seconds**, matching Superwhisper. With only one paste per session there's no back-pressure, but Electron lazy-reads can still push past 500ms; Wispr Flow is the only tool that holds at 500ms and they have telemetry to know it works for them.
6. **Surface the same Wispr fallback.** If `insertViaClipboard` returns false (or if the receiving app silently drops — heuristic: focused-element AX value didn't grow within 200ms of ⌘V), keep the text on the clipboard and post a brief overlay pill: *"Couldn't paste — text is on your clipboard, ⌘V to insert."* Better than silently losing a 30-second dictation.

### What this costs

- A perceptible end-of-dictation latency. Today the user sees their first chunk appear within ~1.5 seconds of starting to speak. After this change, they see nothing in the focused field until they stop. The orb overlay's text stream needs to be visible enough that this feels like a deliberate "review then commit" UX, not a hang. Aqua Voice ships exactly this UX deliberately (their Streaming Mode reframes it as a feature: "edit before paste").
- One real product decision: **do we want streaming visual feedback in the orb, or do we lean into the simpler "talk → release → text appears" UX**? Wispr Flow does the former, Superwhisper/VoiceInk do the latter. I'd lean Wispr-style for Mutter because the orb already exists and dropping live text into it is a tiny addition; keeping the user blind for 8 seconds while they monologue feels worse than necessary.

### What this doesn't cost

- Accuracy — the final transcript is identical, we're just delaying its delivery.
- The keystroke fallback — `insertViaKeystrokes` stays as the tail option and inherits the same commit-once cadence for free.
- Test coverage — `PasteCascade` and `PasteCascadeTests` continue to apply; the cascade is unchanged, the orchestration above it is what shrinks.

## What I'd ship next

A small spike under a feature flag: `Humdrum.dictation.commitOnce = true`. Wire `stop()` to call `PasteHelper.paste(finalText)` a single time, leave `handleTextUpdate` no-op'd behind the flag, and dogfood for a few days. If the long-sentence symptom disappears (it should), promote the flag to default-on and clean up the `pastedText` / `computeDelta` machinery. The PRD is straightforward and I'd expect the patch to be net-negative LOC.

## Sources

- [Wispr Flow — Fix text not pasting after dictation](https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation) — clipboard + ⌘V mechanics, 500ms restore, fallback notification.
- [Wispr Flow — What's new](https://wisprflow.ai/whats-new) — 1.5.2 fixed double-insertion by committing exactly once per dictation.
- [Wispr Flow — Use Flow hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free) — push-to-talk vs. tap-to-toggle, both still paste once.
- [Superwhisper — Advanced Settings](https://superwhisper.com/docs/get-started/settings-advanced) — clipboard default, keystroke as opt-in, 3s restore window, US-QWERTY-only keystroke caveat.
- [Superwhisper — Changelog](https://superwhisper.com/changelog) — paste-once cadence, preserve-clipboard toggle.
- [VoiceInk — GitHub](https://github.com/Beingpax/VoiceInk) — `CursorPaster.pasteAtCursor` is the single paste entry point at end of transcription.
- [VoiceInk Issue #535](https://github.com/Beingpax/VoiceInk/issues/535) — confirms `CursorPaster.pasteAtCursor(textToPaste + " ")` call shape.
- [Aqua Voice — User Guide](https://aquavoice.com/guide) — Streaming Mode shows transcription continuously *for review*, paste-once on confirm.
- [9to5Mac — Aqua Voice review](https://9to5mac.com/2025/08/15/aqua-voice-shows-just-how-good-mac-dictation-could-be/) — sub-second insertion latency, single insertion event.
- [Talon Voice docs](https://talonvoice.com/docs/) — keystroke-based, hybrid command/dictation, not directly comparable.
- Local code references — `Sources/Humdrum/DictationCoordinator.swift`, `Sources/Humdrum/PasteHelper.swift`, `Sources/HumdrumCore/PasteCascade.swift`, `Sources/Humdrum/TranscriptionManager.swift`.
