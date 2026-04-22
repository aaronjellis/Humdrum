import SwiftUI

@main
struct MeetingScribeApp: App {

    // Shared objects — same instances visible to every window + menu bar.
    @StateObject private var manager:    TranscriptionManager
    @StateObject private var store:      SessionStore
    @StateObject private var appState:   AppState
    @StateObject private var dictation:  DictationCoordinator
    @StateObject private var modelCache: ModelCache

    init() {
        // Copy bundled Whisper models (if any) into WhisperKit's cache
        // BEFORE ModelCache scans, so "bundled" shows up as "cached"
        // immediately on first launch.
        BundledModels.installIfNeeded()

        let m  = TranscriptionManager()
        let s  = SessionStore()
        let a  = AppState()
        let d  = DictationCoordinator(manager: m)
        let mc = ModelCache()
        _manager    = StateObject(wrappedValue: m)
        _store      = StateObject(wrappedValue: s)
        _appState   = StateObject(wrappedValue: a)
        _dictation  = StateObject(wrappedValue: d)
        _modelCache = StateObject(wrappedValue: mc)
    }

    var body: some Scene {

        // MARK: Main window
        WindowGroup("Meeting Scribe", id: WindowID.main) {
            ContentView()
                .environmentObject(manager)
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(dictation)
                .environmentObject(modelCache)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    appState.wire(manager: manager, store: store)
                    dictation.installHotkey()
                    // Refresh the cache-status UI whenever a new Whisper
                    // model finishes loading.
                    manager.onModelLoaded = { [weak modelCache] in
                        modelCache?.refresh()
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        // MARK: Pre-recording setup
        Window("New Recording", id: WindowID.setup) {
            SetupWindow()
                .environmentObject(manager)
                .environmentObject(appState)
                .environmentObject(modelCache)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultSize(width: 580, height: 640)

        // MARK: Floating recorder widget
        Window("Recorder", id: WindowID.recorder) {
            RecorderWidget()
                .environmentObject(manager)
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)
        .defaultSize(width: 300, height: 260)

        // MARK: Menu bar extra — dictation status + controls
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(manager)
                .environmentObject(dictation)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)

        // MARK: Native Settings window (⌘,)
        Settings {
            SettingsView()
                .environmentObject(dictation)
                .environmentObject(appState)
        }
    }

    private var menuBarIcon: String {
        if dictation.isDictating { return "waveform.circle.fill" }
        if manager.isRecording   { return "record.circle.fill" }
        return "waveform"
    }
}

// MARK: - Menu bar content

private struct MenuBarContent: View {
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var dictation: DictationCoordinator
    @Environment(\.openWindow)   private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if dictation.isDictating {
                Button("Stop Dictation (⌥Space)") {
                    Task { await dictation.toggle() }
                }
            } else {
                Button("Dictate (⌥Space)") {
                    Task { await dictation.toggle() }
                }
                .disabled(manager.isBusy)
            }

            if !dictation.accessibilityGranted {
                Divider()
                Text("Auto-paste needs Accessibility permission")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider()

            Button("Open Meeting Scribe") {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
