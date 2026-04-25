import SwiftUI
import AppKit

// MARK: - NSWindow customizer

/// Applies "floating recorder" window styling once the view is attached:
/// hides traffic lights, hides the title bar, makes the window draggable
/// by its body, and removes the resize affordance.
struct RecorderWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // IMPORTANT: do NOT override styleMask here.
            //
            // The Window declaration in HumdrumApp already sets
            // `.windowStyle(.hiddenTitleBar)` which gives us exactly what
            // we want: a titled window (so it can become key, so SwiftUI
            // Buttons inside actually fire) with the title bar visually
            // hidden and `.fullSizeContentView` extending the card
            // edge-to-edge.
            //
            // We previously tried:
            //   • `.borderless, .fullSizeContentView` — silently broke
            //     every button inside, because borderless NSWindows
            //     return `canBecomeKey = false` by default and clicks
            //     get eaten by window-activation / drag handling.
            //   • `.titled, .fullSizeContentView` — buttons worked, but
            //     dropping `.closable` / `.resizable` / `.miniaturizable`
            //     broke `dismissWindow(id: .recorder)` so the widget
            //     wouldn't close on Stop.
            //
            // Leaving the SwiftUI-managed styleMask alone fixes both.
            // We only need to hide the traffic lights (SwiftUI leaves
            // them present but the `.hiddenTitleBar` chrome is already
            // invisible — belt-and-suspenders).
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            // Drag by body. Without a visible title bar the user has
            // nothing to grab by default; `isMovableByWindowBackground`
            // makes empty areas of the card act as drag handles. SwiftUI
            // Buttons report `mouseDownCanMoveWindow = false` via their
            // underlying NSControl chain, so clicks on Stop / close fire
            // the action rather than starting a drag.
            window.isMovable = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            // IMPORTANT: window.hasShadow renders a 1px hairline rim at
            // the pixel boundary of the opaque content, which reads as
            // an unwanted outline around our rounded card. The SwiftUI
            // `.shadow(...)` on the card already provides depth, so we
            // explicitly disable the NSWindow-level shadow here to kill
            // the rim.
            window.hasShadow = false
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Recorder widget

/// Tiny, always-on-top floating window shown while recording.
/// Layout (top → bottom):
///   • emerald orb / geometric-web visualizer
///   • one head-truncated line of the most recent transcribed sentence
///   • timer + stop button row
struct RecorderWidget: View {
    @EnvironmentObject var manager: TranscriptionManager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow)    private var openWindow

    @State private var closing: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Rounded translucent card — no border stroke; the drop
            // shadow alone separates it from whatever's behind it.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.panel)
                .shadow(color: .black.opacity(0.55), radius: 26, x: 0, y: 12)

            VStack(spacing: 8) {
                // Orb with a loading state: gray / faded while model
                // loads, plus an explicit ProgressView + "Preparing"
                // label centered on it.
                ZStack {
                    AudioVisualizer(
                        levels: manager.audioLevels,
                        isActive: manager.isRecording,
                        size: 150
                    )
                    .frame(width: 150, height: 150)
                    .saturation(manager.isLoadingModel ? 0 : 1)
                    .opacity(manager.isLoadingModel ? 0.35 : 1)

                    if manager.isLoadingModel {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AppTheme.textSecondary)
                            Text("Preparing model")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
                .padding(.top, 8)

                tickerLine
                    .padding(.horizontal, 14)

                controlRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            // Familiar close affordance in the top-right of the card.
            // DISTINCT from Stop: this discards the in-progress
            // transcript rather than saving it. Stop (the big red
            // button) saves. We prompt for confirmation below if
            // there's anything to lose.
            closeXButton
                .padding(8)
        }
        .frame(width: 300, height: 260)
        .background(RecorderWindowStyler())
        .preferredColorScheme(.dark)
        // Fill the whole window — no slice of empty chrome peeking through
        // above the card.
        .ignoresSafeArea()
        // Reset the `closing` guard every time the widget appears.
        //
        // The recorder Window has a stable id (.recorder) and is a
        // SwiftUI singleton — the view tree survives dismiss/reopen.
        // That means `@State private var closing` persists across
        // sessions: press Stop in session 1 → `closing = true` → widget
        // dismisses → open session 2 → widget reappears with `closing`
        // still true → `.disabled(closing)` disables both Stop and the
        // close X. Resetting on appear scopes the guard to a single
        // Stop press rather than leaking into future sessions.
        .onAppear { closing = false }
    }

    private var closeXButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(Color.white.opacity(0.06))
                )
                .overlay(Circle().stroke(AppTheme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Discard recording")
        .disabled(closing)
    }

    // MARK: Ticker

    private var tickerLine: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.codeBlock)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 0.5)
                )

            Text(tickerText)
                .font(.system(size: 11))
                .foregroundStyle(manager.currentLine.isEmpty
                                 ? AppTheme.textTertiary
                                 : AppTheme.textSecondary)
                .italic(manager.currentLine.isEmpty)
                .lineLimit(1)
                .truncationMode(.head)              // old text trims on the left
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.25), value: manager.currentLine)
        }
        .frame(height: 28)
    }

    // MARK: Bottom row

    private var controlRow: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.danger)
                    .frame(width: 7, height: 7)
                    .shadow(color: AppTheme.danger.opacity(0.7), radius: 4)
                    .opacity(manager.isRecording ? 1 : 0.3)
                Text(manager.elapsedString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer(minLength: 0)

            Button(action: stop) {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .black))
                    Text("Stop")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.danger)            // solid, no gradient
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.6)
                )
                .shadow(color: AppTheme.danger.opacity(0.55), radius: 8)
                .contentShape(Rectangle())            // expand hit area to the full pill
            }
            .buttonStyle(.plain)
            .disabled(closing)
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop and save (⌘.)")
        }
    }

    /// Status text shown in the ticker line. Reflects the manager's
    /// current lifecycle phase so the user isn't staring at a stale
    /// "Listening…" while the model is still loading.
    ///
    /// When none of the lifecycle flags match, fall through to the
    /// manager's `status` string rather than a generic "Ready." — most
    /// silent-fail paths in `manager.start()` (mic denied, model not
    /// loaded, finalizer still running) set `status` to an actionable
    /// message but leave all the flags false, which previously read as
    /// "Ready." in the widget. That gave no clue why recording hadn't
    /// started.
    private var tickerText: String {
        if !manager.currentLine.isEmpty { return manager.currentLine }
        if manager.isLoadingModel       { return "Preparing model…" }
        if manager.isFinalizing         { return "Finalizing…" }
        if manager.isRecording          { return "Listening…" }
        // Initial boot state — the manager hasn't done anything yet.
        if manager.status == "Initializing…" { return "Ready." }
        return manager.status
    }

    // MARK: Stop

    private func stop() {
        guard !closing else { return }
        closing = true

        // Surface the main window, bring the app forward, and drop the
        // widget immediately so the UI feels responsive. Background:
        // manager.stop() runs the last Whisper pass, emits a snapshot that
        // AppState saves, and hands the audio off to the background
        // diarization worker.
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
        dismissWindow(id: WindowID.recorder)

        Task {
            await manager.stop()
        }
    }

    // MARK: Cancel (discard)

    /// Close the widget WITHOUT saving the in-progress transcript.
    /// Prompts for confirmation when there's actual content to lose;
    /// silently closes when the session is empty (user hit record, said
    /// nothing, and bailed — no reason to bother them with a dialog).
    ///
    /// `manager.cancel()` is the fast-path teardown: skips the trailing
    /// Whisper pass, doesn't emit `onSessionCompleted`, so AppState
    /// never sees the session and nothing is persisted.
    private func cancel() {
        guard !closing else { return }

        let hasContent = !manager.confirmedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        if hasContent {
            let alert = NSAlert()
            alert.messageText = "Discard this recording?"
            alert.informativeText =
                "The transcript captured so far will be permanently deleted. "
                + "If you want to save it, click Stop instead."
            alert.alertStyle = .warning
            // Primary-position button is "Keep Recording" so an
            // accidental Return keypress in the alert doesn't destroy
            // the transcript. User has to deliberately pick Discard.
            alert.addButton(withTitle: "Keep Recording")
            let discardButton = alert.addButton(withTitle: "Discard")
            discardButton.hasDestructiveAction = true

            // Default (first) button is Keep; Escape should also be
            // the safe action. macOS maps the second-button default
            // to Escape when no explicit key-equivalent is set.
            guard alert.runModal() == .alertSecondButtonReturn else {
                return
            }
        }

        closing = true

        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
        dismissWindow(id: WindowID.recorder)

        // Synchronous — `cancel()` doesn't run finalize, it just tears
        // down state. No need to wrap in a Task.
        manager.cancel()
    }
}
