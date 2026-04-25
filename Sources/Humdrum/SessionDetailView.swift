import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Read-only view of a previously-recorded session.
///
/// Lives in the main window and is what the user sees immediately after
/// stopping a recording. The transcript is already there (no speaker
/// labels); a spinner in the header indicates when background diarization
/// is still running, and the transcript text re-renders in place once it
/// finishes.
struct SessionDetailView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var appState: AppState
    let session: TranscriptSession

    @State private var showCopyConfirmation: Bool = false
    @State private var isEditingTitle: Bool = false
    @State private var draftTitle: String = ""
    @FocusState private var titleFocused: Bool

    /// True if the background diarization worker is still processing this
    /// specific session. Independent of the manager — the user can be
    /// recording a new session while we show the spinner on an older one.
    private var isDiarizingThisSession: Bool {
        appState.isDiarizing(sessionId: session.id)
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(AppTheme.border)
                metaRow
                Divider().overlay(AppTheme.border)
                transcriptScroll
                Divider().overlay(AppTheme.border)
                footerBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if isEditingTitle {
                TextField("Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($titleFocused)
                    .onSubmit(commitTitleRename)
                    .onExitCommand(perform: cancelTitleRename)
                    .onChange(of: titleFocused) { _, focused in
                        if !focused && isEditingTitle { commitTitleRename() }
                    }
            } else {
                Text(session.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginTitleRename)
                    .contextMenu {
                        Button("Rename", action: beginTitleRename)
                    }
                    .help("Double-click to rename")
            }

            if isDiarizingThisSession {
                diarizingBadge
            }

            Spacer()
            Text(TranscriptSession.formattedDate(session.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Title rename

    private func beginTitleRename() {
        draftTitle = session.title
        isEditingTitle = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitTitleRename() {
        store.rename(session, to: draftTitle)
        isEditingTitle = false
    }

    private func cancelTitleRename() {
        isEditingTitle = false
    }

    private var diarizingBadge: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.accent)
            Text("Analyzing voices…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppTheme.accentSoft))
        .overlay(Capsule().stroke(AppTheme.accentBorder, lineWidth: 0.5))
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            chip(label: "Quality · \(session.settings.quality.capitalized)")
            chip(label: "Noise · \(session.settings.noiseFilter.capitalized)")
            if session.settings.speakerLabelsEnabled {
                chip(label: "Speakers labeled")
            }
            chip(label: durationText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func chip(label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(AppTheme.panel)
            )
            .overlay(
                Capsule().stroke(AppTheme.border, lineWidth: 0.5)
            )
    }

    private var durationText: String {
        let d = session.durationSeconds
        return "Duration · " + String(format: "%d:%02d", d / 60, d % 60)
    }

    private var transcriptScroll: some View {
        ScrollView {
            Text(session.transcriptText.isEmpty ? "(empty transcript)" : session.transcriptText)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(maxHeight: .infinity)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            action(title: showCopyConfirmation ? "Copied!" : "Copy",
                   systemImage: showCopyConfirmation ? "checkmark" : "doc.on.doc",
                   run: copyTranscript)
                .keyboardShortcut("c", modifiers: [.command, .shift])

            action(title: "Save…", systemImage: "square.and.arrow.down", run: save)
                .keyboardShortcut("s", modifiers: [.command])
                .help("Save as .txt or .md")

            Spacer()

            action(title: "Delete", systemImage: "trash", destructive: true, run: delete)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func action(
        title: String,
        systemImage: String,
        destructive: Bool = false,
        run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(destructive ? AppTheme.recording : AppTheme.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(destructive ? AppTheme.recording.opacity(0.15) : AppTheme.panelElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(destructive ? AppTheme.recording.opacity(0.35) : AppTheme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func copyTranscript() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(session.transcriptText, forType: .string)
        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopyConfirmation = false }
    }

    private func save() {
        // All four formats are offered in the panel's File Format
        // dropdown. Default format is the one the user picked in
        // Settings; pre-populated filename carries its extension.
        let markdownType = UTType("net.daringfireball.markdown")
            ?? UTType(filenameExtension: "md", conformingTo: .plainText)
            ?? .plainText
        let rtfType = UTType.rtf
        let jsonType = UTType.json

        let panel = NSSavePanel()
        panel.title = "Save Transcript"
        panel.message = "Choose a folder and format."
        panel.allowedContentTypes = [.plainText, markdownType, rtfType, jsonType]
        panel.canCreateDirectories = true
        panel.showsTagField = false

        if let defaultFolder = appState.defaultSaveFolderURL {
            panel.directoryURL = defaultFolder
        }

        // Pre-select the user's default format via the filename extension.
        panel.nameFieldStringValue = TranscriptExporter.defaultFilename(
            for: session,
            format: appState.defaultSaveFormat
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Resolve the chosen format from whatever extension the panel
        // ended up with. Default to plain text on anything unrecognized.
        let ext = url.pathExtension.lowercased()
        let format = SaveFormat(rawValue: ext == "markdown" ? "md" : ext) ?? .txt

        do {
            try TranscriptExporter.write(session: session, format: format, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save transcript"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func delete() {
        store.delete(session)
        appState.selection = .newSession
    }
}
