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
- When the rolling window passes the configured `maxSegmentSeconds` **or** we detect tail silence longer than `tailSilenceSeconds`, we commit: append the hypothesis to the confirmed transcript and move the commit point forward. Meeting mode (12 s / 1.3 s) and dictation mode (7 s / 0.5 s) use different thresholds; see `CommitThresholds` in `TranscriptionManager.swift`.
- If the commit was triggered by a long silence and speaker labeling is on, we toggle `Speaker 1` / `Speaker 2`.

This is a pragmatic streaming scheme: latency is bounded by the transcription interval (~1.5 s) and the commit window. Accuracy is close to batch mode because each commit always has full sentence context.

## Dictation (⌥Space)

`DictationCoordinator.swift` wraps the same transcription pipeline for a "paste as you speak" flow. A floating glass-orb visualizer appears on activation, the mic starts listening, and whichever field had focus in the frontmost app keeps focus — the orb's `NSPanel` is `nonactivatingPanel`, so it never steals key window status.

### Activation modes

Settings → Dictation → **Activation** picks one:

- **Toggle** (default) — Tap ⌥Space to start, tap again to stop. Phrases get pasted as you pause: ~0.5 s of trailing silence triggers a "phase-1 commit" that pastes the new tail into the focused field, and the engine keeps listening until you tap to stop or stay silent for the full silence-timeout (default 6 s).
- **Push-to-talk** — Hold ⌥Space while you speak, release to commit. The entire utterance is pasted as one chunk on release. No mid-hold pastes — PTT is for the "I want to say one thing and have it land" flow.

Both modes share a Carbon hotkey registration on ⌥Space, so the OS routes the keystroke to Humdrum instead of inserting a non-breaking space into the focused field. Toggle additionally registers ⌥P (pause) and Escape (cancel) while the orb is up.

### Paste cascade

`PasteHelper` + `HumdrumCore.PasteCascade` route every paste through a two-stage strategy:

1. **Clipboard + ⌘V** (primary) — write text to `NSPasteboard`, synthesize ⌘V through the HID event tap, restore the previous clipboard contents 3.0 s later. ⌘V is the single OS-blessed paste event that every mainstream target accepts (Chrome, Electron, Office, JetBrains, Safari, Terminal). Matches what Superwhisper and Wispr Flow default to.
2. **Synthetic Unicode keystrokes** (fallback) — only reached when stage 1 can't construct a `CGEventSource` (rare). Retained for the handful of apps where ⌘V is rebound (vim in a terminal, niche security tools).

AX `kAXSelectedTextAttribute` writes were considered and dropped: too many target apps (Chromium-family browsers, Electron, Office, JetBrains) report `.success` while silently dropping the write, which would leave the user with no signal that paste failed.

The coordinator does a cheap post-paste AX read of the focused element's character count to detect "the cascade reported success but the receiving app dropped it" — a known failure mode for Electron renderers. When it triggers, a `silentDrop` failure pill tells the user the text is on their clipboard for a manual ⌘V.

### Pause / cancel / failure feedback

- **⌥P** — Pause (toggle mode only). Engine stays hot, orb dims, no auto-stop fires while paused. Tap again to resume.
- **Escape** — Cancel (toggle mode only). Orb flashes red and tears down without pasting whatever new tail accumulated since the last commit.
- **Failure pill** — Below the orb. Surfaces missing Accessibility, paste failure (empty clipboard fallback), silent drop (Electron-style consume-but-drop), or a transient "Transcribing…" indicator while the tail Whisper pass runs after a long PTT release.

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

## Updates

Humdrum self-updates via [Sparkle 2](https://sparkle-project.org). `SparkleUpdater.swift` wraps `SPUStandardUpdaterController` against the appcast URL in `Info.plist`'s `SUFeedURL` (currently a GitHub Pages-hosted feed). The updater fires a quiet background check ~5 s after launch and on a daily schedule; **App menu → Check for Updates…** triggers a user-facing check.

Each downloaded update is verified against the ed25519 public key in `Info.plist` (`SUPublicEDKey`); the matching private key signs releases in CI ([.github/workflows/release.yml](.github/workflows/release.yml)). Pushing a `vX.Y.Z` tag to `main` triggers the full pipeline: build → Developer-ID sign → Apple notarize → staple → Sparkle-sign zip → publish GitHub Release → update appcast on `gh-pages`. End-to-end runbook for one-time setup (keys, secrets, Pages, smoke test) lives in [Docs/SPARKLE_SETUP.md](Docs/SPARKLE_SETUP.md).

## Known limitations

- **Microphone only.** Capturing system audio (e.g., Zoom's far-side audio) needs a virtual audio driver like [BlackHole](https://github.com/ExistentialAudio/BlackHole) or a multi-output device. You then select that device as your system mic before starting. The app itself needs no change.
- **Diarization accuracy depends on speaker distinctness.** Two voices that sound very similar (same age/gender/accent, similar pitch) can still get merged. If that happens on a specific recording, the audio itself is ambiguous — no local model will fix it.
- First run of any model has a one-time download + compile step that can take 30–90 seconds. The UI stays responsive and the status bar tells you what's happening.
- A short trailing utterance may be held in the "hypothesis" buffer until you hit **Stop**; stopping always does a final pass over any uncommitted audio.

## Keyboard shortcuts

- `⌥Space` — Toggle dictation, or hold for push-to-talk (mode picked in Settings → Dictation). Global.
- `⌥P` — Pause an in-flight toggle-mode dictation (engine stays hot, no auto-stop). Tap again to resume.
- `Escape` — Cancel an in-flight toggle-mode dictation without pasting the unflushed tail.
- `⌘R` — Start / stop recording (in-app)
- `⌘⇧C` — Copy transcript
- `⌘S` — Save transcript

## Project layout

```
Humdrum/
├── Package.swift                               Swift package; depends on WhisperKit + FluidAudio + Sparkle
├── Info.plist                                  Bundle metadata, mic copy, Sparkle keys
├── Humdrum.entitlements                        Hardened-runtime + mic entitlements
├── build-app.sh                                Builds, signs, notarizes, staples, zips
├── .github/workflows/release.yml               Tag → build → notarize → publish + appcast
├── Docs/SPARKLE_SETUP.md                       One-time release-pipeline runbook
├── README.md
├── Sources/HumdrumCore/                        Pure-logic library, no AppKit / AVFoundation
│   ├── PasteCascade.swift                      Clipboard-first → keystroke fallback strategy
│   ├── DictationActivationMode.swift           toggle vs. pushToTalk enum
│   ├── NoiseFilterLevel.swift                  Off / Light / Normal / Strict thresholds
│   ├── NoiseSanitizer.swift                    Whisper-hallucination filter ("Thanks for watching")
│   ├── FuzzyMatcher.swift                      Token-level diff for the corrections-store learning loop
│   ├── TextChunker.swift                       Default chunk size for the dictation paste path
│   ├── TranscriptDelta.swift                   Diff-paste utilities
│   └── WordStream.swift                        Per-session word IDs for ticker animations
└── Sources/Humdrum/
    ├── HumdrumApp.swift                        @main entry, window setup, wake re-warm
    ├── AppState.swift                          Shared state, auto-save, diarization worker
    ├── AppMark.swift, Theme.swift              App-icon / palette tokens
    ├── ContentView.swift                       Main SwiftUI window
    ├── Sidebar.swift, RecordingView.swift,
    │   RecorderWidget.swift                    Main-window UI
    ├── DictationCoordinator.swift              ⌥Space session lifecycle, race guards, paste orchestration
    ├── DictationOverlay.swift                  Floating non-activating orb panel + status pill
    ├── AudioVisualizer.swift                   Glass-sphere visualizer
    ├── HotkeyManager.swift                     Carbon RegisterEventHotKey wrapper (press + release)
    ├── PushToTalkMonitor.swift                 PTT press/release driven by Carbon hotkey on ⌥Space
    ├── PasteHelper.swift                       AX probes, frontmost-app metadata, real paste backend
    ├── Diagnostics.swift                       Per-subsystem os.log channels
    ├── CorrectionsStore.swift                  Persisted user-corrections for the learning loop
    ├── SessionStore.swift                      Persisted transcript store
    ├── SessionDetailView.swift                 Session view + corrections capture UI
    ├── ModelCache.swift, BundledModels.swift   Whisper model resolution + warmup
    ├── DiarizationService.swift                FluidAudio post-stop speaker pass
    ├── TranscriptExporter.swift                Shared save logic (.txt/.md/.rtf/.json)
    ├── SetupWindow.swift, OnboardingState.swift,
    │   OnboardingWindow.swift                  First-launch flow
    ├── MoveToApplications.swift                First-launch move prompt
    ├── UserDefaultsMigrator.swift              Legacy "MeetingScribe.*" key migration
    ├── SettingsView.swift                      ⌘, Settings window (incl. Diagnostics row)
    ├── SparkleUpdater.swift                    Sparkle 2 wrapper + menu binding
    ├── WindowID.swift                          SceneStorage scene IDs
    └── TranscriptionManager.swift              Audio capture, streaming transcription, finalize
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
