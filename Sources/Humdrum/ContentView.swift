import SwiftUI

/// Main window root: sidebar on the left, detail pane on the right. The
/// detail either shows a selected session's transcript or a welcome state
/// prompting the user to hit Start Recording.
struct ContentView: View {
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(recordingInProgress: manager.isRecording)
                .frame(width: 260)

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1)

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
        .preferredColorScheme(.dark)
        // NOTE: No auto-download on launch. Everything local-first:
        // the transcription model only downloads the first time the user
        // picks a Quality and presses Start; diarization model only the
        // first time a recording stops with "Label speakers" enabled.
        // Nothing else in this app makes network calls.
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selection {
        case .newSession:
            WelcomeView()
        case .session(let id):
            if let session = store.session(with: id) {
                SessionDetailView(session: session)
            } else {
                WelcomeView()
            }
        }
    }
}
