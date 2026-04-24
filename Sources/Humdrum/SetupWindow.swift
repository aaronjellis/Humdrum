import SwiftUI
import AppKit
import HumdrumCore

/// Pre-meeting setup. A small, visually engaging window where the user
/// picks quality/noise/speakers with icon tiles instead of dropdowns,
/// then hits Start. Opens the Recorder widget and closes itself.
struct SetupWindow: View {
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var modelCache: ModelCache
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var advancedExpanded: Bool = false
    @State private var starting: Bool = false

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    qualitySection
                    noiseSection
                    speakersSection
                    advancedSection
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }

            VStack {
                Spacer()
                footerBar
            }
        }
        .frame(minWidth: 560, idealWidth: 580, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [AppTheme.accent, AppTheme.accent.opacity(0.3)],
                                center: .center, startRadius: 2, endRadius: 16)
                        )
                        .frame(width: 24, height: 24)
                        .shadow(color: AppTheme.accentGlow, radius: 8)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("New Recording")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text("Pick how you want the transcript to behave, then start when you're ready.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: Quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Quality")
            HStack(spacing: 10) {
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
            Text(manager.qualityLevel.description)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            // Selected-quality download summary, spelled out so nothing
            // happens silently when the user hits Start.
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
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Noise filter")
            HStack(spacing: 10) {
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
            Text(manager.noiseFilterLevel.description)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Speakers")

            Button { manager.speakerLabelsEnabled.toggle() } label: {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    manager.speakerLabelsEnabled
                                    ? AppTheme.accentSoft
                                    : AppTheme.panelElevated
                                )
                                .frame(width: 44, height: 44)
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(
                                    manager.speakerLabelsEnabled
                                    ? AppTheme.accent
                                    : AppTheme.textSecondary
                                )
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Label speakers after recording")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("Off by default. Transcript appears instantly with no labels; a local diarization model runs in the background and rewrites it with Speaker 1 / 2 / 3 tags.")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 0)

                        Toggle("", isOn: $manager.speakerLabelsEnabled)
                            .toggleStyle(.switch)
                            .tint(AppTheme.accent)
                            .labelsHidden()
                    }

                    // Explicit consent block — only visible when ON.
                    if manager.speakerLabelsEnabled {
                        downloadConsentNote
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            manager.speakerLabelsEnabled ? AppTheme.accentBorder : AppTheme.border,
                            lineWidth: 0.7
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Surfaces the fact that enabling Speakers means downloading an
    /// additional ~80 MB of local ML models (pyannote segmentation +
    /// speaker embeddings) the first time this recording Stops. Everything
    /// runs on-device after that.
    private var downloadConsentNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Downloads a separate package on first use")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("~80 MB of voice-embedding models (pyannote + speaker ID) from Hugging Face, saved to ~/Library/Caches. After that it's 100% offline and never re-downloaded.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.accentBorder, lineWidth: 0.5)
        )
    }

    // MARK: Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Advanced")
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 6) {
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

                    Text("Optional. Seed the model with proper nouns, brand names, or jargon. Skip this if you don't need it.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("Name hints")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("optional")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            .tint(AppTheme.textSecondary)
        }
        .padding(.bottom, 88) // leave room above the sticky footer
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
            let inFlight = starting || manager.isBusy
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
        // The model only (re)loads if the picked Quality differs from
        // what's currently cached — usually zero wait after first launch.
        if manager.needsReload { return "Start Recording" }
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
