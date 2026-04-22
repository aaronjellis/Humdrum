# Humdrum

A lightweight, **100% local**, native SwiftUI Mac app that records your microphone and produces a live transcript you can copy or save. Also a global dictation hotkey (⌥Space) that pastes Whisper transcriptions into whatever field you're typing in. Nothing leaves your machine.

- Native Swift / SwiftUI — no Electron, no browser
- Local transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper compiled to Core ML, runs on the Apple Neural Engine)
- Live / streaming UI: confirmed text in black, in-flight hypothesis in gray italic
- Pick your model: Tiny → Base → Small → Medium (accuracy vs. speed)
- Global ⌥Space dictation — speak, text appears in the focused field
- Copy to clipboard, Save as `.txt` / `.md` / `.rtf` / `.json`, or auto-save to a folder
- Real local speaker diarization via [FluidAudio](https://github.com/FluidInference/FluidAudio) (pyannote-segmentation + speaker-embedding models in Core ML). Runs once when you click Stop.
- Adjustable noise filter (Off / Light / Normal / Strict) to keep Whisper from hallucinating "Thanks for watching" during silent stretches.

> The model itself is local Whisper. Accuracy is competitive with cloud Whisper.

---

## Requirements

- macOS 14 (Sonoma) or newer — Apple Silicon strongly recommended
- Xcode 15+ **or** Swift 5.9+ command-line tools (`xcode-select --install`)
- ~150 MB of free space for the recommended `base.en` model (first launch downloads it once, then caches)

## Quick start

```bash
cd Humdrum
./build-app.sh --skip-notarize   # fast dev build
open ./Humdrum.app
```

On first launch:

1. Humdrum will offer to move itself into `/Applications` — accept it so TCC permissions stick.
2. macOS will ask for Microphone permission — approve it.
3. Grant Accessibility in System Settings → Privacy & Security → Accessibility (needed for ⌥Space dictation to paste into other apps).
4. The app downloads the selected Whisper model from Hugging Face on first use. Subsequent launches are instant.

### Shipping to someone else

Run the full release pipeline (signs with Developer ID, enables hardened runtime, notarizes with Apple, and staples the ticket onto the bundle):

```bash
./build-app.sh
```

Hand over the resulting `Humdrum.zip`. They unzip, drag `Humdrum.app` into `/Applications`, and launch normally — no right-click-open dance, no Gatekeeper warnings.

One-time setup for notarization (see `build-app.sh` header for the full list):

```bash
xcrun notarytool store-credentials humdrum-notary \
    --apple-id "you@example.com" \
    --team-id  "YOUR_TEAM_ID" \
    --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
```

---

## How it works

```
           ┌───────────────┐         ┌────────────────────┐
 Mic ─────▶│ AVAudioEngine │ ──────▶ │ WhisperKit         │ ──▶ Transcript
           │ (16 kHz PCM)  │  floats │ (Core ML / ANE)    │
           └───────────────┘         └────────────────────┘
                     ▲                          │
                     │                          ▼
                  rolling                  every ~1.5s,
                  buffer                  re-transcribe
                                          the uncommitted window
```

`TranscriptionManager.swift` drives everything:

- `AudioProcessor` (from WhisperKit) captures microphone audio into a rolling `[Float]` buffer at 16 kHz.
- Every ~1.5 s we transcribe the portion since the last *commit point* and show it as a "live hypothesis" (italic gray).
- When the window grows past ~18 s **or** we detect ~1.3 s of tail silence, we commit: append the hypothesis to the confirmed transcript and move the commit point forward.
- If the commit was triggered by a long silence and speaker labeling is on, we toggle `Speaker 1` / `Speaker 2`.

This is a pragmatic streaming scheme: latency is bounded by the transcription interval (~1.5 s) and the commit window. Accuracy is close to batch mode because each commit always has full sentence context.

## Dictation (⌥Space)

`DictationCoordinator.swift` wraps the same transcription pipeline for a "paste as you speak" flow:

1. ⌥Space → a floating glass-orb visualizer appears, the mic starts listening, and whichever field had focus in the frontmost app keeps focus (the orb's NSPanel is non-activating).
2. As Whisper commits chunks, `PasteHelper` inserts them into the focused field — first via the Accessibility API (`kAXSelectedTextAttribute`), falling back to synthesized ⌘V through the HID event tap when AX insertion isn't supported.
3. 2.5 s of silence (configurable in Settings) or another ⌥Space stops dictation and hides the orb.

If Accessibility permission is missing, the orb still runs but each chunk only lands on the clipboard — a red warning pill appears under the orb so the failure mode isn't silent.

## Quality levels

The UI's **Quality** picker maps to underlying Whisper models. Pick by what matters to you, not by filename.

| UI label     | Whisper model | Size  | Typical WER (English) | Pick when…                                               |
|--------------|---------------|-------|-----------------------|----------------------------------------------------------|
| Fast         | tiny.en       | 75 MB | ~12–14%               | personal notes, short memos                               |
| **Balanced** | **base.en**   | 145 MB | ~8–10%                | **default; casual meetings**                              |
| Accurate     | small.en      | 490 MB | ~5–7%                 | work meetings you'll share                                |
| Best         | medium.en     | 1.5 GB | ~4–5%                 | critical transcripts; longer to start, uses more RAM      |

Changing Quality triggers a one-time download of the new model. All models here are English-only (`.en`). Remove the `.en` suffix in `TranscriptionManager.swift`'s `QualityLevel.modelId` if you need multilingual.

## Names, jargon, and the "Names & terms" field

Whisper learns spellings from its training corpus. For rare proper nouns ("Edgar", "Aanya", "Zephyr"), brand names ("Anthropic", "GitLab"), and acronyms, the smaller models will just guess — usually phonetically.

The **Names & terms** field in the UI is wired into Whisper's *initial prompt*. It's a list of words/phrases that gets tokenized and prepended to the decoder context, biasing the model toward those spellings. Example:

> `Aaron Ellis, Anthropic, Claude, Cowork, Project Zephyr, Dr. Patel, NPS, MQLs`

In practice this is the single biggest accuracy lever short of upgrading the model. Keep it under ~50 words; longer prompts get truncated. If names still come out wrong even with hints, move up one quality level.

## Speaker labels (diarization)

If **Label speakers after recording** is on, clicking Stop runs FluidAudio's diarizer on the full session audio, extracts a voice embedding per detected speech segment, clusters the embeddings, and rewrites the transcript with `Speaker 1:` / `Speaker 2:` / … labels in order of first appearance. Speakers are renumbered consistently across the whole session.

Why post-processing instead of live labels? Streaming diarization that keeps speaker IDs consistent across chunks is a research problem; running the full pass once at the end gives dramatically better clustering, and the short wait is worth accurate labels.

Delay on Stop is roughly 2–6 s per minute of audio on Apple Silicon. First ever run downloads the diarization models (~80 MB) to `~/Library/Caches` and then caches them forever.

## Auto-save

Settings → Transcripts lets you pick a default folder and format, and toggle **Save to default folder automatically**. When that toggle is on, finished recordings are written to the folder immediately — no Save dialog — with filename collisions resolved by appending `-1`, `-2`, etc. The in-app session still exists, so Save… from the detail view remains available.

## Known limitations

- **Microphone only.** Capturing system audio (e.g., Zoom's far-side audio) needs a virtual audio driver like [BlackHole](https://github.com/ExistentialAudio/BlackHole) or a multi-output device. You then select that device as your system mic before starting. The app itself needs no change.
- **Diarization accuracy depends on speaker distinctness.** Two voices that sound very similar (same age/gender/accent, similar pitch) can still get merged. If that happens on a specific recording, the audio itself is ambiguous — no local model will fix it.
- First run of any model has a one-time download + compile step that can take 30–90 seconds. The UI stays responsive and the status bar tells you what's happening.
- A short trailing utterance may be held in the "hypothesis" buffer until you hit **Stop**; stopping always does a final pass over any uncommitted audio.

## Keyboard shortcuts

- `⌥Space` — Start / stop dictation (global)
- `⌘R` — Start / stop recording (in-app)
- `⌘⇧C` — Copy transcript
- `⌘S` — Save transcript

## Project layout

```
Humdrum/
├── Package.swift                               Swift package, depends on WhisperKit + FluidAudio
├── Info.plist                                  Bundle metadata + mic permission copy
├── Humdrum.entitlements                        Hardened-runtime + mic entitlements
├── build-app.sh                                Builds, signs, notarizes, staples, zips
├── README.md
└── Sources/Humdrum/
    ├── HumdrumApp.swift                        @main entry, window setup
    ├── AppState.swift                          Shared state, auto-save, diarization worker
    ├── ContentView.swift                       Main SwiftUI window
    ├── DictationCoordinator.swift              ⌥Space dictation orchestration
    ├── DictationOverlay.swift                  Floating non-activating orb panel
    ├── AudioVisualizer.swift                   Glass-sphere visualizer
    ├── PasteHelper.swift                       AX-insert / ⌘V paste strategies
    ├── MoveToApplications.swift                First-launch move prompt
    ├── UserDefaultsMigrator.swift              Legacy "MeetingScribe.*" key migration
    ├── TranscriptExporter.swift                Shared save logic (.txt/.md/.rtf/.json)
    ├── SessionStore.swift                      Persisted transcript store
    ├── SettingsView.swift                      ⌘, Settings window
    └── TranscriptionManager.swift              Audio capture + streaming transcription
```

## Troubleshooting

**"Could not start mic…"** — Open `System Settings → Privacy & Security → Microphone` and tick `Humdrum`. If it isn't listed, delete `Humdrum.app`, run `./build-app.sh` again, and relaunch.

**Dictation orb bounces but no text appears** — Accessibility permission is missing or stale. Settings → Dictation → "Reset & Re-grant…". Rebuilding an ad-hoc-signed app changes the binary signature, which can invalidate the existing TCC row.

**Notarization failed** — Get the full log:
```bash
xcrun notarytool history --keychain-profile humdrum-notary
xcrun notarytool log <submission-id> --keychain-profile humdrum-notary
```
Most common causes: an entitlement that requires a provisioning profile you don't have, or unsigned binaries inside an SPM `.bundle`. The build script walks and pre-signs nested dylibs/frameworks/bundles specifically to avoid this.

**Model download stuck** — WhisperKit caches models under `~/Library/Caches/com.argmax.whisperkit` (or similar). Delete that folder and reload to retry.

**Transcript lags or repeats words** — That's usually the "hypothesis" being updated in-place. It stabilizes as soon as it gets committed. If you want fewer commits, bump `maxSegmentSeconds` in `TranscriptionManager.swift`; for lower latency, lower `transcribeIntervalSeconds`.

**`swift build` errors about WhisperKit version** — Versions move; if `from: "0.9.0"` in `Package.swift` no longer resolves, check the [WhisperKit releases page](https://github.com/argmaxinc/WhisperKit/releases) and update the version constraint.

## License

Your choice. WhisperKit is MIT-licensed. Whisper model weights are MIT-licensed by OpenAI.
