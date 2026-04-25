import SwiftUI
import AppKit

@main
struct HumdrumApp: App {

    // Shared objects — same instances visible to every window + menu bar.
    @StateObject private var manager:    TranscriptionManager
    @StateObject private var store:      SessionStore
    @StateObject private var appState:   AppState
    @StateObject private var dictation:  DictationCoordinator
    @StateObject private var modelCache: ModelCache
    @StateObject private var onboarding: OnboardingState
    @StateObject private var updater:    SparkleUpdater

    @MainActor
    init() {
        // Offer to move to /Applications before anything else. If the
        // user accepts, the original launch terminates mid-init and we
        // relaunch from the copy in /Applications, so it's safe to do
        // this before the heavy setup below.
        MoveToApplications.offerIfNeeded()

        // Migrate UserDefaults from the old "MeetingScribe.*" namespace
        // to "Humdrum.*" so users who had the dev build keep their
        // preferences. Cheap, idempotent, safe to call every launch.
        UserDefaultsMigrator.migrateLegacyKeysIfNeeded()

        // Copy bundled Whisper models (if any) into WhisperKit's cache
        // BEFORE ModelCache scans, so "bundled" shows up as "cached"
        // immediately on first launch.
        BundledModels.installIfNeeded()

        let m  = TranscriptionManager()
        let s  = SessionStore()
        let a  = AppState()
        let d  = DictationCoordinator(manager: m)
        let mc = ModelCache()
        let ob = OnboardingState()
        let up = SparkleUpdater()
        _manager    = StateObject(wrappedValue: m)
        _store      = StateObject(wrappedValue: s)
        _appState   = StateObject(wrappedValue: a)
        _dictation  = StateObject(wrappedValue: d)
        _modelCache = StateObject(wrappedValue: mc)
        _onboarding = StateObject(wrappedValue: ob)
        _updater    = StateObject(wrappedValue: up)
    }

    var body: some Scene {

        // MARK: Main window — gated behind onboarding.
        //
        // First-run: show OnboardingWindow until the user finishes the
        // flow (persists "Humdrum.onboarded.v1" in UserDefaults). After
        // that, cold launches skip straight to ContentView. We reuse
        // the same WindowGroup so the window identity/size persists
        // across the swap instead of a second window opening.
        WindowGroup("Humdrum", id: WindowID.main) {
            Group {
                if onboarding.isOnboarded {
                    ContentView()
                } else {
                    OnboardingWindow()
                }
            }
            .environmentObject(manager)
            .environmentObject(store)
            .environmentObject(appState)
            .environmentObject(dictation)
            .environmentObject(modelCache)
            .environmentObject(onboarding)
            .environmentObject(updater)
            .frame(minWidth: 900, minHeight: 620)
            .task {
                appState.wire(manager: manager, store: store)
                dictation.installHotkey()
                // Refresh the cache-status UI whenever a new Whisper
                // model finishes loading.
                manager.onModelLoaded = { [weak modelCache] in
                    modelCache?.refresh()
                }
                // Pre-warm the Whisper model on launch IF we already
                // have it on disk. This turns the first ⌥Space into an
                // instant paste instead of a 2–4 s model-load hang. We
                // deliberately do NOT trigger a download here — that'd
                // surprise the user with a silent ~150 MB–1.5 GB fetch
                // on every fresh install. The Setup window / onboarding
                // is the right place for the first download.
                if onboarding.isOnboarded,
                   modelCache.isCached(manager.qualityLevel),
                   manager.needsReload {
                    await manager.loadModel()
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Standard macOS home for "Check for Updates…": just
            // below "About Humdrum" in the application menu. Dims
            // while a check is already in flight so users can't pile
            // up concurrent network requests.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheck)
            }
        }

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
                .environmentObject(updater)
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
    @EnvironmentObject var updater: SparkleUpdater
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

            Button("Open Humdrum") {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheck)

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
