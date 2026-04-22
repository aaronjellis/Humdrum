# Meeting Scribe

A lightweight, **100% local**, native SwiftUI Mac app that records your microphone and produces a live transcript you can copy or save. Nothing leaves your machine.

- Native Swift / SwiftUI — no Electron, no browser
- Local transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper compiled to Core ML, runs on the Apple Neural Engine)
- Live / streaming UI: confirmed text in black, in-flight hypothesis in gray italic
- Pick your model: Tiny → Base → Small → Medium (accuracy vs. speed)
- Copy to clipboard, Save as `.txt`
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
cd MeetingScribe
./build-app.sh
open ./MeetingScribe.app
```

On first launch:

1. macOS will ask for Microphone permission — approve it.
2. The app will download the selected Whisper model from Hugging Face (progress shown in the status bar). Subsequent launches are instant.
3. Click **Start Recording**, speak, click **Stop**. Use **Copy** to grab the transcript.

### Or run from source without building a bundle

```bash
swift run -c release
```

This skips the `.app` wrapper. macOS may show a generic permission prompt or the prompt may not appear cleanly — `./build-app.sh` is the recommended path.

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

## Known limitations

- **Microphone only.** Capturing system audio (e.g., Zoom's far-side audio) needs a virtual audio driver like [BlackHole](https://github.com/ExistentialAudio/BlackHole) or a multi-output device. You then select that device as your system mic before starting. The app itself needs no change.
- **Diarization accuracy depends on speaker distinctness.** Two voices that sound very similar (same age/gender/accent, similar pitch) can still get merged. If that happens on a specific recording, the audio itself is ambiguous — no local model will fix it.
- First run of any model has a one-time download + compile step that can take 30–90 seconds. The UI stays responsive and the status bar tells you what's happening.
- A short trailing utterance may be held in the "hypothesis" buffer until you hit **Stop**; stopping always does a final pass over any uncommitted audio.

## Keyboard shortcuts

- `⌘R` — Start / Stop recording
- `⌘⇧C` — Copy transcript
- `⌘S` — Save transcript

## Project layout

```
MeetingScribe/
├── Package.swift                              Swift package, depends on WhisperKit
├── Info.plist                                 Bundle metadata + mic permission copy
├── build-app.sh                               Builds & wraps into MeetingScribe.app
├── README.md
└── Sources/MeetingScribe/
    ├── MeetingScribeApp.swift                 @main entry, window setup
    ├── ContentView.swift                      SwiftUI UI (header, controls, transcript, footer)
    └── TranscriptionManager.swift             Audio capture + streaming transcription logic
```

## Troubleshooting

**"Could not start mic…"** — Open `System Settings → Privacy & Security → Microphone` and tick `MeetingScribe`. If it isn't listed, delete `MeetingScribe.app`, run `./build-app.sh` again, and relaunch.

**Model download stuck** — WhisperKit caches models under `~/Library/Caches/com.argmax.whisperkit` (or similar). Delete that folder and reload to retry.

**Transcript lags or repeats words** — That's usually the "hypothesis" being updated in-place. It stabilizes as soon as it gets committed. If you want fewer commits, bump `maxSegmentSeconds` in `TranscriptionManager.swift`; for lower latency, lower `transcribeIntervalSeconds`.

**`swift build` errors about WhisperKit version** — Versions move; if `from: "0.9.0"` in `Package.swift` no longer resolves, check the [WhisperKit releases page](https://github.com/argmaxinc/WhisperKit/releases) and update the version constraint.

## License

Your choice. WhisperKit is MIT-licensed. Whisper model weights are MIT-licensed by OpenAI.
