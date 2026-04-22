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
            // Force a truly borderless window — SwiftUI's
            // .windowStyle(.hiddenTitleBar) still reserves a few pixels
            // of window gutter at top and bottom. Replacing the style
            // mask outright removes all of that. We don't need standard
            // controls (traffic lights, titlebar drag, resize) because
            // we supply our own close X + stop button and the window
            // isn't resizable or draggable by titlebar.
            window.styleMask = [.borderless, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
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
            // Rounded translucent card
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            manager.isRecording ? AppTheme.accentBorder : AppTheme.border,
                            lineWidth: 0.7
                        )
                )
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
            // Same effect as Stop: save the transcript and hide.
            closeXButton
                .padding(8)
        }
        .frame(width: 300, height: 260)
        .background(RecorderWindowStyler())
        .preferredColorScheme(.dark)
        // Fill the whole window — no slice of empty chrome peeking through
        // above the card.
        .ignoresSafeArea()
    }

    private var closeXButton: some View {
        Button(action: stop) {
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
        .help("Stop and save")
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
    private var tickerText: String {
        if !manager.currentLine.isEmpty { return manager.currentLine }
        if manager.isLoadingModel       { return "Preparing model…" }
        if manager.isFinalizing         { return "Finalizing…" }
        if manager.isRecording          { return "Listening…" }
        return "Ready."
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
}
