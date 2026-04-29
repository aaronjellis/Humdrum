import SwiftUI
import AppKit
import HumdrumCore
import WhisperKit  // for the DeviceID typealias used by the mic picker

/// Pre-meeting setup. A small, visually engaging window where the user
/// picks quality/noise/speakers with icon tiles instead of dropdowns,
/// then hits Start. Opens the Recorder widget and closes itself.
struct SetupWindow: View {
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var modelCache: ModelCache
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var starting: Bool = false
    @State private var diarizationDownload: DiarizationDownloadState = .idle

    /// State machine for the diarization-model download triggered when
    /// the user enables speaker labels. Driven by FluidAudio's
    /// `DiarizerModels.downloadIfNeeded(progressHandler:)`. The download
    /// is idempotent on disk — calling when files are already cached
    /// resolves immediately, which lands us in `.ready` after a single
    /// progressHandler call at fractionCompleted=1.
    enum DiarizationDownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case ready
        case failed(String)

        var isInFlight: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            // Single non-scrolling column. Sections are sized to fit
            // the default window without scrolling — quick glance,
            // pick, hit Start. The in-content header is gone (the
            // macOS title bar already says "New Recording", which is
            // configured at the WindowGroup level).
            VStack(alignment: .leading, spacing: 14) {
                micSection
                qualitySection
                noiseSection
                speakersRow
                nameHintsField
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 64)   // leave room above the sticky footer

            VStack {
                Spacer()
                footerBar
            }
        }
        .frame(minWidth: 560, idealWidth: 580, minHeight: 720)
        .preferredColorScheme(.dark)
        // Reset the `starting` guard every time the window appears.
        //
        // Setup is a SwiftUI Window with a stable id (.setup) — the
        // view tree survives dismiss/reopen, which means local @State
        // persists across sessions. If startRecording()'s Task ever
        // exits without hitting `starting = false` (crash, unhandled
        // error, user force-quit mid-load), the next time the user
        // opens Setup the Start button is stuck disabled. Resetting
        // on appear scopes the guard to a single Start press.
        .onAppear {
            starting = false
            manager.refreshInputDevices()
        }
        // If the user has speakers ON when Setup opens (from a prior
        // session, or persisted across launches), kick off the model
        // download check immediately so the Start button isn't gated
        // by a download that hasn't started yet.
        .task(id: manager.speakerLabelsEnabled) {
            if manager.speakerLabelsEnabled {
                await ensureDiarizationModels()
            } else {
                diarizationDownload = .idle
            }
        }
    }

    // MARK: Diarization download

    /// Triggered the first time the user flips speakers ON in this Setup
    /// session (or re-opens Setup with it already on). Calls FluidAudio's
    /// idempotent download API and renders progress into the speakers row.
    /// While in flight, the Start button is disabled — submitting before
    /// the model is on disk would force the recorder to do the download
    /// during Stop, which is exactly the ambiguous "stuck" UX we want to
    /// avoid.
    private func ensureDiarizationModels() async {
        if case .ready = diarizationDownload { return }
        if diarizationDownload.isInFlight { return }
        diarizationDownload = .downloading(progress: 0)
        do {
            try await DiarizationService.downloadModelsIfNeeded { fraction in
                Task { @MainActor in
                    // Only update if we're still in the downloading state —
                    // protects against late callbacks after the user
                    // flipped the toggle off and we re-set to .idle.
                    if case .downloading = diarizationDownload {
                        diarizationDownload = .downloading(progress: fraction)
                    }
                }
            }
            diarizationDownload = .ready
        } catch {
            diarizationDownload = .failed(error.localizedDescription)
        }
    }

    // MARK: Header

    // MARK: Microphone

    /// Compact input-device picker. Drives `manager.selectedInputDeviceID`,
    /// which `manager.start()` passes to `AudioProcessor.startRecordingLive`.
    /// Without this UI the user had no way to override the system default
    /// — meaning a Bluetooth headset that's paired but unworn would
    /// silently feed zero-valued samples into Whisper, with no UX recourse.
    private var micSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Microphone")
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Picker("", selection: micPickerBinding) {
                    Text("System default").tag(DeviceID?.none)
                    if !manager.availableInputDevices.isEmpty {
                        Divider()
                        ForEach(manager.availableInputDevices) { dev in
                            Text(dev.name).tag(DeviceID?.some(dev.id))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .tint(AppTheme.textPrimary)

                Button { manager.refreshInputDevices() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Re-scan input devices")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 0.5)
            )
        }
    }

    /// Tiny shim so the SwiftUI `Picker` can bind to an optional
    /// DeviceID. SwiftUI's tagged Pickers handle optionals with
    /// matching tag types; we're explicit about the bridge so the
    /// "System default" sentinel (.none) round-trips cleanly through
    /// the manager's `selectedInputDeviceID` setter.
    private var micPickerBinding: Binding<DeviceID?> {
        Binding(
            get: { manager.selectedInputDeviceID },
            set: { manager.selectedInputDeviceID = $0 }
        )
    }

    // MARK: Quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Quality")
            HStack(spacing: 8) {
                ForEach(QualityLevel.allCases) { q in
                    IconTile(
                        icon: iconForQuality(q),
                        accent: accentForQuality(q),
                        title: q.shortLabel,
                        subtitle: shortBlurb(for: q),
                        cacheState: cacheState(for: q),
                        isSelected: manager.qualityLevel == q,
                        action: { if !manager.isBusy { manager.qualityLevel = q } }
                    )
                    .disabled(manager.isBusy)
                    .opacity(manager.isBusy && manager.qualityLevel != q ? 0.4 : 1)
                }
            }
            // Single-line "what'll happen on Start" line — replaces the
            // longer per-level paragraph that used to live here. The
            // per-level blurb already shows on the tile itself.
            downloadSummary
        }
    }

    private func cacheState(for q: QualityLevel) -> QualityCacheState {
        if modelCache.isBundled(q) { return .bundled }
        if modelCache.isCached(q)  { return .cached }
        return .needsDownload(sizeText: q.sizeDescription)
    }

    /// Plain-English summary of what pressing Start will do, given the
    /// currently selected Quality level.
    @ViewBuilder
    private var downloadSummary: some View {
        let q = manager.qualityLevel
        let state = cacheState(for: q)
        HStack(spacing: 8) {
            Image(systemName: state.iconName)
                .font(.system(size: 11))
                .foregroundStyle(state.tint)
            Text(state.verboseText(for: q))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func iconForQuality(_ q: QualityLevel) -> String {
        switch q {
        case .fast:     return "hare.fill"
        case .balanced: return "scalemass.fill"
        case .accurate: return "scope"
        case .best:     return "sparkles"
        }
    }

    private func accentForQuality(_ q: QualityLevel) -> Color {
        // Progression: coolest → warmest for a nice gradient across the row
        switch q {
        case .fast:     return AppTheme.circle3        // teal
        case .balanced: return AppTheme.accent         // emerald
        case .accurate: return AppTheme.circle2        // lavender
        case .best:     return AppTheme.circle1        // rose
        }
    }

    private func shortBlurb(for q: QualityLevel) -> String {
        switch q {
        case .fast:     return "Near-instant"
        case .balanced: return "Good default"
        case .accurate: return "Names + jargon"
        case .best:     return "Highest accuracy"
        }
    }

    // MARK: Noise

    private var noiseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Noise filter")
            HStack(spacing: 8) {
                ForEach(NoiseFilterLevel.allCases) { lvl in
                    IconTile(
                        icon: iconForNoise(lvl),
                        accent: AppTheme.accent,
                        title: lvl.shortLabel,
                        subtitle: shortBlurb(for: lvl),
                        isSelected: manager.noiseFilterLevel == lvl,
                        action: { manager.noiseFilterLevel = lvl }
                    )
                }
            }
            // The per-level blurb on the tile itself ("Recommended" /
            // "Skip silence" / etc) is enough — dropped the verbose
            // paragraph that used to live here.
        }
    }

    private func iconForNoise(_ lvl: NoiseFilterLevel) -> String {
        switch lvl {
        case .off:    return "speaker.wave.3.fill"
        case .light:  return "speaker.wave.2.fill"
        case .normal: return "speaker.wave.1.fill"
        case .strict: return "speaker.slash.fill"
        }
    }

    private func shortBlurb(for lvl: NoiseFilterLevel) -> String {
        switch lvl {
        case .off:    return "Everything"
        case .light:  return "Skip silence"
        case .normal: return "Recommended"
        case .strict: return "Speech only"
        }
    }

    // MARK: Speakers

    /// Compact one-row toggle. Used to be a tall card; now the same row
    /// surfaces the speaker-model cache state (`Cached` / `~80 MB`),
    /// flips into a progress bar while downloading, and lands on
    /// `Ready ✓` when complete. Mirrors the `cacheState` pattern used
    /// by the Quality tiles so users see one consistent "model status"
    /// affordance everywhere a download might be required.
    private var speakersRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(
                    manager.speakerLabelsEnabled ? AppTheme.accent : AppTheme.textSecondary
                )
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("Label speakers after recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                speakerModelStatusLine
            }

            Spacer(minLength: 0)

            Toggle("", isOn: $manager.speakerLabelsEnabled)
                .toggleStyle(.switch)
                .tint(AppTheme.accent)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    manager.speakerLabelsEnabled ? AppTheme.accentBorder : AppTheme.border,
                    lineWidth: 0.5
                )
        )
    }

    /// One-line status under the speakers toggle. Drives the same
    /// affordance the Quality tiles use for cache state, but rendered
    /// inline (no IconTile shape — there's only one item) and with an
    /// integrated progress bar when a download is in flight. Order of
    /// precedence: in-flight download wins over cached/idle copy.
    @ViewBuilder
    private var speakerModelStatusLine: some View {
        switch diarizationDownload {
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(AppTheme.accent)
                    .frame(maxWidth: 140)
                Text("Downloading speaker model — \(Int(progress * 100))%")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        case .ready:
            cacheBadge(
                icon: "checkmark.circle.fill",
                text: "Speaker model ready",
                tint: AppTheme.accent
            )
        case .failed(let msg):
            cacheBadge(
                icon: "exclamationmark.triangle.fill",
                text: "Download failed: \(msg)",
                tint: AppTheme.danger
            )
        case .idle:
            // Toggle off, or just-opened with no decision yet.
            // Distinguish cached vs. needs-download so the user knows
            // what flipping the toggle on will trigger.
            if DiarizationService.areModelsCached() {
                cacheBadge(
                    icon: "checkmark.circle.fill",
                    text: "Speaker model cached locally",
                    tint: AppTheme.accent
                )
            } else {
                cacheBadge(
                    icon: "arrow.down.circle",
                    text: "Downloads ~80 MB on first use, then offline forever",
                    tint: AppTheme.textSecondary
                )
            }
        }
    }

    /// Pill-style badge — matches the visual language of the Quality
    /// tile's `cacheState` indicator so the speakers row reads as a
    /// peer of the model picker rather than a separate idiom.
    private func cacheBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(tint)
    }

    // MARK: Name hints

    /// Always-visible single-line text field for the vocabulary prompt.
    /// Was a DisclosureGroup; that hid the field by default and added
    /// an extra click for a setting that's actually high-value when the
    /// recording involves named people, products, or jargon.
    private var nameHintsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionLabel("Names & terms")
                Text("optional")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textTertiary)
                    .padding(.bottom, 1)
            }
            TextField(
                "e.g. Aaron Ellis, Anthropic, Project Zephyr, Dr. Patel",
                text: $manager.vocabularyHints
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppTheme.codeBlock)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 0.5)
            )
        }
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack {
            Button("Cancel") {
                dismissWindow(id: WindowID.setup)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Spacer()

            // Only show the spinner when a job is actively in flight —
            // NOT when the model simply isn't loaded yet (that's the
            // normal idle state on first launch, and the button needs to
            // be clickable so Start can trigger the first load).
            //
            // We also gate on the diarization download: if speakers are
            // ON and that model isn't ready yet, kicking off recording
            // would force the download to happen during Stop instead,
            // which is the ambiguous "stuck" UX we wanted to avoid.
            let diarizationGate = manager.speakerLabelsEnabled
                && diarizationDownload != .ready
                && DiarizationService.areModelsCached() == false
            let inFlight = starting || manager.isBusy || diarizationGate
            Button(action: startRecording) {
                HStack(spacing: 9) {
                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black.opacity(0.7))
                    } else {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(primaryButtonLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accent, AppTheme.accentDim],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: AppTheme.accentGlow, radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [AppTheme.background.opacity(0), AppTheme.background],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(AppTheme.textTertiary)
    }

    private var primaryButtonLabel: String {
        if starting {
            if manager.isLoadingModel {
                return "Preparing \(manager.qualityLevel.shortLabel) model…"
            }
            return "Starting…"
        }
        if let reason = manager.busyReason { return reason }
        if manager.speakerLabelsEnabled && diarizationDownload.isInFlight {
            if case .downloading(let progress) = diarizationDownload {
                return "Downloading speaker model — \(Int(progress * 100))%"
            }
            return "Downloading speaker model…"
        }
        // The model only (re)loads if the picked Quality differs from
        // what's currently cached — usually zero wait after first launch.
        return "Start Recording"
    }

    private func startRecording() {
        guard !starting, !manager.isBusy else { return }

        // If a download is about to happen, confirm with the user first.
        // Skipped entirely for Quality levels that are bundled or cached.
        let q = manager.qualityLevel
        let willDownload = manager.needsReload
            && !modelCache.isBundled(q)
            && !modelCache.isCached(q)
        if willDownload && !confirmWhisperDownload(for: q) {
            return
        }

        starting = true

        // Show the recorder widget IMMEDIATELY — the orb appears and
        // gives the user feedback while the model loads in the
        // background. Main + Setup both close so only the orb is
        // on-screen.
        openWindow(id: WindowID.recorder)
        dismissWindow(id: WindowID.setup)
        dismissWindow(id: WindowID.main)

        Task {
            if manager.needsReload {
                await manager.loadModel()
            }
            guard manager.modelLoaded else {
                // Load failed — close the recorder so user isn't stuck
                dismissWindow(id: WindowID.recorder)
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
                starting = false
                return
            }
            await manager.start()
            starting = false
        }
    }

    /// Modal confirmation before downloading a Whisper model. Returns
    /// `true` if the user agreed, `false` otherwise.
    private func confirmWhisperDownload(for q: QualityLevel) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the \(q.shortLabel) transcription model?"
        alert.informativeText = """
            Humdrum needs to fetch the Whisper \(q.shortLabel) model (\(q.sizeDescription)) \
            from Hugging Face the first time you use it. Saved to \
            ~/Documents/huggingface/models — cached forever after, runs entirely on-device. \
            No other network access.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Start")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Cache state badge

enum QualityCacheState: Equatable {
    case bundled                        // ships inside the .app
    case cached                         // user downloaded previously
    case needsDownload(sizeText: String)

    var badgeText: String {
        switch self {
        case .bundled:                   return "Included"
        case .cached:                    return "Cached"
        case .needsDownload(let size):   return size
        }
    }

    var iconName: String {
        switch self {
        case .bundled:          return "shippingbox.fill"
        case .cached:           return "checkmark.circle.fill"
        case .needsDownload:    return "arrow.down.circle"
        }
    }

    var tint: Color {
        switch self {
        case .bundled, .cached:   return AppTheme.accent
        case .needsDownload:      return AppTheme.textSecondary
        }
    }

    func verboseText(for q: QualityLevel) -> String {
        switch self {
        case .bundled:
            return "\(q.shortLabel) is included in the app — no download needed."
        case .cached:
            return "\(q.shortLabel) (\(q.sizeDescription)) is already on your Mac."
        case .needsDownload:
            return "Pressing Start will download the \(q.shortLabel) model (\(q.sizeDescription)) once. Cached forever after that."
        }
    }
}

// MARK: - Reusable icon tile

private struct IconTile: View {
    let icon: String
    let accent: Color
    let title: String
    let subtitle: String
    var cacheState: QualityCacheState? = nil   // only Quality tiles use this
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.18) : AppTheme.panelElevated)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : AppTheme.textSecondary)
                }
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                if let cacheState {
                    HStack(spacing: 3) {
                        Image(systemName: cacheState.iconName)
                            .font(.system(size: 8, weight: .semibold))
                        Text(cacheState.badgeText)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(cacheState.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(cacheState.tint.opacity(0.12))
                    )
                    .overlay(
                        Capsule().stroke(cacheState.tint.opacity(0.35), lineWidth: 0.5)
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                        ? accent.opacity(0.06)
                        : (hovering ? Color.white.opacity(0.025) : AppTheme.panel)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? accent.opacity(0.55) : AppTheme.border,
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
            .shadow(color: isSelected ? accent.opacity(0.25) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
