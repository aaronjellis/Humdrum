import SwiftUI
import AppKit
import HumdrumCore

// MARK: - Window wrapper

/// Full-window first-run flow. Runs before the main UI is visible so the
/// user's first real recording has no surprises (permissions, voice
/// model, save folder) other than the one download they explicitly
/// accept on the voice-model panel.
///
/// The flow itself is seven panels managed by `OnboardingState`. Each
/// panel is a self-contained subview so they're easy to edit in
/// isolation without threading layout through a single 500-line body.
struct OnboardingWindow: View {
    @EnvironmentObject var onboarding: OnboardingState
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var modelCache: ModelCache

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            // Subtle emerald wash in the corner to match the rest of
            // the app's stage backgrounds.
            AppTheme.stageGradient
                .opacity(0.7)
                .ignoresSafeArea()

            Group {
                switch onboarding.currentPanel {
                case .welcome:
                    WelcomePanel()
                case .features:
                    FeaturesPanel()
                case .activation:
                    ActivationModePanel()
                case .voiceModel:
                    VoiceModelPanel()
                case .permissions:
                    PermissionsPanel()
                case .folder:
                    FolderPanel()
                case .success:
                    SuccessPanel()
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.28), value: onboarding.currentPanel)
        }
        .frame(minWidth: 640, minHeight: 560)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Shared panel scaffolding

/// Common chrome around each panel: centered column, max width, top +
/// bottom padding, progress dots. Keeps every screen in-rhythm without
/// each panel redoing the layout math.
private struct PanelScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    let panel: OnboardingState.Panel
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                content()
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 32)

            Spacer(minLength: 0)

            ProgressDots(active: panel)
                .padding(.bottom, 28)
        }
    }
}

private struct ProgressDots: View {
    let active: OnboardingState.Panel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingState.Panel.allCases, id: \.rawValue) { panel in
                Capsule()
                    .fill(panel == active ? AppTheme.accent : AppTheme.border)
                    .frame(width: panel == active ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.22), value: active)
            }
        }
    }
}

// MARK: - 1. Welcome

private struct WelcomePanel: View {
    @EnvironmentObject var onboarding: OnboardingState

    // Gentle synthetic levels drive the orb's breathing animation —
    // same visual language the success panel uses so the user meets
    // the orb early and sees it again at the end of the flow.
    private let ambientLevels: [Float] = [0.32, 0.24, 0.40]

    var body: some View {
        PanelScaffold(
            title: "Hi, I'm Humdrum.",
            subtitle: nil,
            panel: .welcome
        ) {
            VStack(spacing: 28) {
                ZStack {
                    AudioVisualizer(
                        levels: ambientLevels,
                        isActive: true,
                        size: 160
                    )
                    // 👋 layered on the orb. A rotation wiggle gives a
                    // natural wave — pivoting at the bottom so the
                    // "wrist" stays put and only the hand moves.
                    WavingHand()
                }
                .frame(width: 180, height: 180)

                Text("I turn what you say into text. In meetings you're recording, or anywhere you can type. Everything happens on your Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)

                PrimaryButton(title: "Get started") {
                    onboarding.next()
                }
            }
        }
    }
}

/// A waving 👋 — tilts back and forth indefinitely. Pivots at the
/// bottom of the glyph (roughly the wrist) so the motion reads as a
/// wave rather than a shimmy. Kept as its own view so the repeating
/// animation has a stable identity and doesn't restart when the
/// enclosing panel re-renders.
private struct WavingHand: View {
    @State private var angle: Double = -12

    var body: some View {
        Text("👋")
            .font(.system(size: 54))
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                ) {
                    angle = 12
                }
            }
    }
}

// MARK: - 2. Features

/// Explains the two distinct things Humdrum does so first-time users
/// know what they just installed. Before this panel existed, people
/// would finish onboarding and only find the Meeting recorder — Mutter
/// was a hidden ⌥Space easter egg they'd discover by accident (or not
/// at all). Two cards, same visual rhythm, kept deliberately short so
/// the panel doesn't feel like a marketing page.
private struct FeaturesPanel: View {
    @EnvironmentObject var onboarding: OnboardingState

    var body: some View {
        PanelScaffold(
            title: "Two ways to turn speech into text.",
            subtitle: "Both run on your Mac. Nothing leaves the device.",
            panel: .features
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    FeatureCard(
                        icon: "waveform.circle.fill",
                        title: "Meeting Recorder",
                        copy: "Record a conversation and get a full transcript, with optional speaker labels. Start it from the main window or the menu bar."
                    )

                    FeatureCard(
                        icon: "keyboard.fill",
                        title: "Mutter (⌥ Space)",
                        copy: "Press ⌥Space anywhere — Slack, browser, Notes, email — speak, and your words appear in whatever field had focus. Stops on its own after a short silence."
                    )
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "Back") {
                        onboarding.back()
                    }
                    PrimaryButton(title: "Continue") {
                        onboarding.next()
                    }
                }
            }
        }
    }
}

/// A single explainer card used by FeaturesPanel. Icon in a tinted
/// square, title, short description. Visually aligned with PermissionRow
/// so the onboarding flow has consistent card rhythm from top to bottom.
///
/// Note: the stored caption is `copy` rather than `body` because `body`
/// is SwiftUI's view-builder property on `View` and the names collide.
private struct FeatureCard: View {
    let icon: String
    let title: String
    let copy: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.accentSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(copy)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .configonautCard(tinted: false)
    }
}

// MARK: - 3. Activation mode

/// Lets the user choose between tap-to-toggle and press-and-hold for
/// the Mutter ⌥Space binding. The default we'd pick for them is
/// `.toggle` (matches Whisper Flow / Superwhisper, the most common
/// dictation pattern), but on first run we surface the choice
/// explicitly so users in loud environments — where silence-based
/// auto-stop misfires — can pick PTT before they ever experience the
/// frustration. Two cards, same visual rhythm as the FeaturesPanel.
private struct ActivationModePanel: View {
    @EnvironmentObject var onboarding: OnboardingState
    @EnvironmentObject var dictation: DictationCoordinator

    var body: some View {
        PanelScaffold(
            title: "How do you want to start dictating?",
            subtitle: "Want to press and hold to dictate, or press once and let it listen, then stop when you stop talking?",
            panel: .activation
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    ForEach(DictationActivationMode.allCases, id: \.self) { mode in
                        ActivationModeCard(
                            mode: mode,
                            selected: dictation.activationMode == mode
                        ) {
                            dictation.activationMode = mode
                        }
                    }
                }

                Text("You can change this any time in Settings → Dictation.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textTertiary)

                HStack(spacing: 10) {
                    SecondaryButton(title: "Back") {
                        onboarding.back()
                    }
                    PrimaryButton(title: "Continue") {
                        onboarding.next()
                    }
                }
            }
        }
    }
}

/// One card for each activation mode. Visually mirrors `FeatureCard`
/// (same padding, same icon-square treatment) but adds a radio-style
/// selection indicator on the trailing edge so the panel reads as
/// "pick one" rather than "two things you can do."
private struct ActivationModeCard: View {
    let mode: DictationActivationMode
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? AppTheme.accentSoft : AppTheme.panelElevated)
                        .frame(width: 40, height: 40)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selected ? AppTheme.accent : AppTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.shortLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(mode.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .configonautCard(tinted: selected)
        }
        .buttonStyle(.plain)
    }

    /// Per-mode glyph. Tap-to-toggle reads as a single keystroke;
    /// press-and-hold gets a "hand pressing keys" feel.
    private var iconName: String {
        switch mode {
        case .toggle:     return "hand.tap.fill"
        case .pushToTalk: return "hand.point.up.left.fill"
        }
    }
}

// MARK: - 4. Voice model

private struct VoiceModelPanel: View {
    @EnvironmentObject var onboarding: OnboardingState
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var modelCache: ModelCache

    var body: some View {
        PanelScaffold(
            title: "Pick a voice model.",
            subtitle: "You can change this later.",
            panel: .voiceModel
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    ForEach(QualityLevel.allCases) { level in
                        VoiceModelRow(
                            level: level,
                            selected: manager.qualityLevel == level,
                            state: state(for: level)
                        ) {
                            manager.qualityLevel = level
                        }
                    }
                }

                Text("Downloads once. Works offline after that.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textTertiary)

                if let error = onboarding.modelDownloadError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "Back") {
                        onboarding.back()
                    }
                    .disabled(onboarding.isDownloadingModel)

                    PrimaryButton(
                        title: continueTitle,
                        busy: onboarding.isDownloadingModel
                    ) {
                        Task { await advance() }
                    }
                    .disabled(onboarding.isDownloadingModel)
                }
            }
        }
    }

    private var continueTitle: String {
        if onboarding.isDownloadingModel { return "Downloading…" }
        if modelCache.isCached(manager.qualityLevel) { return "Continue" }
        return "Download and continue"
    }

    private func state(for level: QualityLevel) -> VoiceModelRow.State {
        if modelCache.isBundled(level) { return .included }
        if modelCache.isCached(level)  { return .ready }
        return .downloadable(size: level.sizeDescription)
    }

    private func advance() async {
        onboarding.modelDownloadError = nil
        // Already on disk: just continue.
        if modelCache.isCached(manager.qualityLevel) {
            onboarding.next()
            return
        }
        // Otherwise kick off the WhisperKit download. No progress API,
        // so it's indeterminate — the Continue button just switches to
        // "Downloading…" until loadModel returns.
        onboarding.isDownloadingModel = true
        await manager.loadModel()
        modelCache.refresh()
        onboarding.isDownloadingModel = false
        if modelCache.isCached(manager.qualityLevel) {
            onboarding.next()
        } else {
            onboarding.modelDownloadError =
                "Couldn't download the voice model. Check your connection and try again."
        }
    }
}

private struct VoiceModelRow: View {
    enum State {
        case included                       // shipped inside the app bundle
        case ready                          // cached on disk
        case downloadable(size: String)     // not yet on disk
    }

    let level: QualityLevel
    let selected: Bool
    let state: State
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.textTertiary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(level.shortLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(shortDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                stateBadge
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .configonautCard(tinted: selected)
        }
        .buttonStyle(.plain)
    }

    private var shortDescription: String {
        switch level {
        case .fast:     return "Quick, looser with names and jargon."
        case .balanced: return "A good starting point for most people."
        case .accurate: return "Sharper on names, acronyms, and jargon."
        case .best:     return "Most accurate. Uses more of your Mac."
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .included:
            Badge(text: "Included", tint: .accent)
        case .ready:
            Badge(text: "Ready", tint: .accent)
        case .downloadable(let size):
            Badge(text: "about \(cleaned(size))", tint: .neutral)
        }
    }

    /// Strip the tilde WhisperKit uses in raw size strings so the UI
    /// reads as plain English ("about 145 MB", not "about ~145 MB").
    private func cleaned(_ raw: String) -> String {
        raw.replacingOccurrences(of: "~", with: "")
    }
}

private struct Badge: View {
    enum Tint { case accent, neutral }
    let text: String
    let tint: Tint

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(background)
            )
            .overlay(
                Capsule(style: .continuous).stroke(border, lineWidth: 0.7)
            )
    }

    private var foreground: Color {
        switch tint {
        case .accent:  return AppTheme.accent
        case .neutral: return AppTheme.textSecondary
        }
    }
    private var background: Color {
        switch tint {
        case .accent:  return AppTheme.accentSoft
        case .neutral: return AppTheme.panelElevated
        }
    }
    private var border: Color {
        switch tint {
        case .accent:  return AppTheme.accentBorder
        case .neutral: return AppTheme.border
        }
    }
}

// MARK: - 5. Permissions

private struct PermissionsPanel: View {
    @EnvironmentObject var onboarding: OnboardingState

    var body: some View {
        PanelScaffold(
            title: "Two quick permissions.",
            subtitle: "Humdrum won't work without them.",
            panel: .permissions
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    PermissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        subtitle: "So Humdrum can hear you.",
                        granted: onboarding.micGranted,
                        buttonTitle: onboarding.micGranted ? "Granted" : "Allow"
                    ) {
                        Task { await onboarding.requestMicrophone() }
                    }

                    PermissionRow(
                        icon: "keyboard.fill",
                        title: "Keyboard control",
                        subtitle: "So Mutter can type into other apps when you press ⌥Space.",
                        granted: onboarding.accessibilityGranted,
                        buttonTitle: onboarding.accessibilityGranted ? "Granted" : "Allow"
                    ) {
                        onboarding.requestAccessibility()
                    }
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "Back") {
                        onboarding.back()
                    }
                    PrimaryButton(title: "Continue") {
                        onboarding.next()
                    }
                    .disabled(!onboarding.bothPermissionsGranted)
                }
            }
        }
        .onAppear { onboarding.startPermissionPolling() }
        .onDisappear { onboarding.stopPermissionPolling() }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(granted ? AppTheme.accentSoft : AppTheme.panelElevated)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(granted ? AppTheme.accent : AppTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Granted")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AppTheme.accent)
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous).fill(AppTheme.accentSoft)
                        )
                        .overlay(
                            Capsule(style: .continuous).stroke(AppTheme.accentBorder, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .configonautCard(tinted: granted)
    }
}

// MARK: - 6. Folder

private struct FolderPanel: View {
    @EnvironmentObject var onboarding: OnboardingState
    @EnvironmentObject var appState: AppState

    var body: some View {
        PanelScaffold(
            title: "Want to save your recordings to a folder?",
            subtitle: "I'll drop each recording in there automatically, so you don't have to remember to save.",
            panel: .folder
        ) {
            VStack(spacing: 20) {
                if let folder = appState.defaultSaveFolderURL {
                    FolderPill(folder: folder, onChange: pickFolder, onClear: clearFolder)
                } else {
                    Button(action: pickFolder) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 14, weight: .medium))
                            Text("Choose a folder…")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.accentSoft)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.accentBorder, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "Back") {
                        onboarding.back()
                    }
                    PrimaryButton(title: "Finish") {
                        onboarding.next()
                    }
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // NSOpenPanel defaults this to false, which grays out the
        // "New Folder" button in the picker UI. Users reading the
        // message "Pick a folder for Humdrum to save recordings into"
        // naturally want to make a fresh ~/Humdrum or similar right
        // there — without this flag they have to quit, open Finder,
        // create the folder, and come back.
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Pick a folder for Humdrum to save recordings into."
        // Start in a sensible place rather than wherever the last
        // NSOpenPanel across the whole user session happened to land.
        if let existing = appState.defaultSaveFolderURL {
            panel.directoryURL = existing
        } else if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            panel.directoryURL = docs
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.defaultSaveFolderPath = url.path
            // Folder chosen = auto-save on. Folded into a single
            // concept per the user spec: no separate toggle.
            appState.autoSaveOnRecordEnd = true
        }
    }

    private func clearFolder() {
        appState.defaultSaveFolderPath = nil
        appState.autoSaveOnRecordEnd = false
    }
}

private struct FolderPill: View {
    let folder: URL
    let onChange: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(folder.path)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("Change", action: onChange)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.accent)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Clear folder (turns off auto-save)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .configonautCard(tinted: true)
    }
}

// MARK: - 7. Success

private struct SuccessPanel: View {
    @EnvironmentObject var onboarding: OnboardingState

    // Gentle synthetic levels so the orb breathes without a live mic
    // feed. Values picked to sit in the middle of the visualizer's
    // intensity range; it reads as "humming" rather than "silent."
    private let ambientLevels: [Float] = [0.32, 0.24, 0.40]

    var body: some View {
        PanelScaffold(
            title: "Everything's humming.",
            subtitle: nil,
            panel: .success
        ) {
            VStack(spacing: 28) {
                ZStack {
                    AudioVisualizer(
                        levels: ambientLevels,
                        isActive: true,
                        size: 200
                    )
                    // Checkmark overlaid on the orb. White glyph with a
                    // soft glow so it reads cleanly against the bright
                    // sphere without feeling pasted on.
                    Image(systemName: "checkmark")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 2)
                        .shadow(color: AppTheme.accent.opacity(0.5), radius: 16)
                }
                .frame(width: 220, height: 220)

                PrimaryButton(title: "Open Humdrum") {
                    onboarding.finish()
                }
            }
        }
    }
}

// MARK: - Buttons

private struct PrimaryButton: View {
    let title: String
    var busy: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.textPrimary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? Color.black : AppTheme.textTertiary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isEnabled ? AppTheme.accent : AppTheme.panelElevated)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? AppTheme.textPrimary : AppTheme.textTertiary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.panelElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
    }
}
