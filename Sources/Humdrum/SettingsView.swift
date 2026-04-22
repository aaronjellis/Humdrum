import SwiftUI
import AppKit

/// Native Settings window (⌘,). Two tabs: Dictation and About.
struct SettingsView: View {
    var body: some View {
        TabView {
            DictationSettingsTab()
                .tabItem { Label("Dictation", systemImage: "waveform") }

            TranscriptsSettingsTab()
                .tabItem { Label("Transcripts", systemImage: "doc.text") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 440)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Transcripts tab

private struct TranscriptsSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default save folder")
                            .fontWeight(.medium)
                        Text(displayText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { pickFolder() }
                    if appState.defaultSaveFolderPath != nil {
                        Button("Clear") { appState.defaultSaveFolderPath = nil }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Save")
            } footer: {
                Text("Save dialogs open to this folder by default. You can still pick a different folder per-file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Default format", selection: $appState.defaultSaveFormat) {
                        ForEach(SaveFormat.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(appState.defaultSaveFormat.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Default format")
            } footer: {
                Text("Pre-selected in the Save dialog. You can still pick any format per-file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $appState.autoSaveOnRecordEnd) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save to default folder automatically")
                        Text("When a recording ends, write the transcript to your default folder using your default format — no Save dialog.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(AppTheme.accent)
                // NOTE: intentionally NOT .disabled() when the default
                // folder is unset. A disabled toggle that silently
                // refuses to flip reads as broken; instead we allow the
                // flip and surface the inline warning below so the
                // user understands *why* nothing will save.

                if appState.autoSaveOnRecordEnd && appState.defaultSaveFolderPath == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.danger)
                            .font(.caption)
                        Text("Pick a default save folder above first — auto-save has nowhere to write until you do.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Auto-save")
            } footer: {
                Text("Duplicate filenames get a numeric suffix (for example, My-transcript-2026-04-22-0935-1.md) so back-to-back recordings never overwrite each other.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    private var displayText: String {
        if let path = appState.defaultSaveFolderPath, !path.isEmpty {
            // Show ~/Documents instead of /Users/foo/Documents when applicable.
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return "Ask each time (defaults to Documents)"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose default save folder"
        panel.prompt = "Use This Folder"
        if let existing = appState.defaultSaveFolderURL {
            panel.directoryURL = existing
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.defaultSaveFolderPath = url.path
        }
    }
}

// MARK: - Dictation tab

private struct DictationSettingsTab: View {
    @EnvironmentObject var dictation: DictationCoordinator

    // Polls Accessibility permission so when the user flips it on in
    // System Settings we reflect the new state without requiring a click.
    private let permissionPoll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $dictation.hotkeyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global hotkey for dictation")
                        Text("Press **⌥Space** from any app to start dictating into the focused text field. Press again or pause for 2.5 s to stop.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(AppTheme.accent)

                hotkeyDisplay
                    .padding(.top, 4)
            } header: {
                Text("Hotkey")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Auto-stop after")
                        Spacer()
                        Text(String(format: "%.1fs of silence", dictation.silenceTimeoutSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $dictation.silenceTimeoutSeconds,
                        in: 1.0...5.0,
                        step: 0.5
                    )
                    .tint(AppTheme.accent)
                    Text("Dictation stops on its own when you've been silent for this long. Hitting ⌥Space always stops immediately.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Silence detection")
            }

            Section {
                accessibilityRow
            } header: {
                Text("Paste into focused field")
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onReceive(permissionPoll) { _ in
            // Live-update the Accessibility indicator so the user sees
            // the state flip to granted within ~1.5 s of enabling it
            // (silent — no system prompt).
            dictation.refreshAccessibilityStatus()
        }
    }

    private var hotkeyDisplay: some View {
        HStack(spacing: 8) {
            Text("Current binding:")
                .foregroundStyle(.secondary)
            Text("⌥ Space")
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppTheme.panelElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 0.5)
                )
            Spacer()
            Text("Rebinding coming soon")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: dictation.accessibilityGranted
                      ? "checkmark.shield.fill"
                      : "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(dictation.accessibilityGranted
                                     ? AppTheme.accent
                                     : AppTheme.danger)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dictation.accessibilityGranted
                         ? "Accessibility permission granted"
                         : "Accessibility permission not granted")
                        .fontWeight(.medium)
                    Text(dictation.accessibilityGranted
                         ? "Dictation can paste directly into the focused field."
                         : "Without this, dictation still copies text to the clipboard, but can't auto-paste.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if !dictation.accessibilityGranted {
                    Button("Open Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            // Reset-stale-grant hint — this is the fix for "I already
            // enabled it but it still says not granted." Rebuilding an
            // ad-hoc-signed app changes the binary signature, so the
            // existing TCC row is effectively for a different app. The
            // button below clears that row so the user can re-grant
            // cleanly.
            if !dictation.accessibilityGranted {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Already toggled Humdrum on?")
                            .font(.footnote.weight(.medium))
                        Text("Rebuilt copies of the app sometimes read as a new application to macOS. Reset the existing row and re-grant.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Reset & Re-grant…") {
                        dictation.resetAccessibilityPermission()
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 0.5)
                )
            }
        }
    }
}

// MARK: - About tab

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accentDim],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: AppTheme.accentGlow, radius: 10)
                Image(systemName: "waveform")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 2) {
                Text("Humdrum")
                    .font(.title2.bold())
                Text("Local transcripts & dictation, on-device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Pull the version + build straight out of Info.plist at
            // runtime so "am I actually on the latest build?" is a
            // quick glance in Settings → About rather than a chain of
            // Finder/Dock/LaunchServices cache voodoo. build-app.sh
            // auto-increments CFBundleVersion on every run.
            Text(Self.versionString)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .textSelection(.enabled)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                privacyLine("Microphone", "Used locally to capture audio. Never uploaded.")
                privacyLine("Whisper model", "Downloaded once from Hugging Face per Quality level. Then 100% offline.")
                privacyLine("Speaker model", "Optional. 80 MB, downloaded only when Speakers is first turned on.")
                privacyLine("No telemetry", "Zero analytics, crash reports, or update checks.")
            }
            .frame(maxWidth: 420)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    /// e.g. "v0.2.0 (build 47)". Built once at first access so we
    /// don't pay the Info.plist lookup on every view update. If
    /// the keys are ever missing (unsigned dev run from SwiftPM,
    /// say), falls back to a hardcoded "v0.0.0 (dev)" so the UI
    /// still renders rather than silently collapsing the Text.
    private static let versionString: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "dev"
        return "v\(short) (build \(build))"
    }()

    private func privacyLine(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.caption)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(body).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
