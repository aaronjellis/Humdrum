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
    @EnvironmentObject var corrections: CorrectionsStore
    let session: TranscriptSession

    @State private var showCopyConfirmation: Bool = false
    @State private var isEditingTitle: Bool = false
    @State private var draftTitle: String = ""
    @FocusState private var titleFocused: Bool

    // Correction sheet state.
    //
    // Tonight's slice: a button in the footer opens this sheet where the
    // user types what Humdrum heard vs. what they meant. Per-word
    // double-click lands in a follow-on evening once we decide between
    // mode-toggle and NSTextViewRepresentable for the per-word
    // interaction (both compatible with this same data model).
    @State private var showCorrectionSheet: Bool = false
    @State private var correctionHeard: String = ""
    @State private var correctionMeant: String = ""
    @State private var correctionScope: CorrectionScope = .global
    @State private var showTeachConfirmation: Bool = false

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
        .sheet(isPresented: $showCorrectionSheet) {
            correctionSheet
        }
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

            // Tonight's primary learning-loop entry point. The
            // gamified onboarding banner ("Want Humdrum to learn how
            // you speak?") and the per-word double-click flow are
            // phase α follow-ons that ride on this same record() path.
            action(title: showTeachConfirmation ? "Saved" : "Teach…",
                   systemImage: showTeachConfirmation ? "checkmark" : "graduationcap",
                   run: beginTeach)
                .help("File a correction so Humdrum gets future transcripts right")

            // Visible badge of how many corrections are already on this
            // session. Cheap and informative — turns the abstract
            // "learning" idea into a concrete count the user has been
            // building up. No-op when zero so we don't clutter.
            if !sessionCorrections.isEmpty {
                Text("\(sessionCorrections.count) correction\(sessionCorrections.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppTheme.accentSoft))
                    .overlay(Capsule().stroke(AppTheme.accentBorder, lineWidth: 0.5))
            }

            Spacer()

            action(title: "Delete", systemImage: "trash", destructive: true, run: delete)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Corrections filed against this specific session. Drives the
    /// "N corrections" badge in the footer.
    private var sessionCorrections: [Correction] {
        corrections.corrections(for: session.id)
    }

    // MARK: Correction sheet

    private func beginTeach() {
        // Pre-populate the "heard" field with whatever the user has
        // currently selected in the transcript text view, if anything.
        // SwiftUI doesn't expose a clean "what's selected" hook on
        // Text(.textSelection(.enabled)), so we read the system
        // pasteboard's "find" buffer if the user just hit ⌘E, falling
        // back to empty otherwise. This is good-enough seeding —
        // worst case the user types both fields manually.
        let findBoard = NSPasteboard(name: .find)
        let seeded = findBoard.string(forType: .string) ?? ""
        correctionHeard = seeded
        correctionMeant = ""
        correctionScope = .global
        showCorrectionSheet = true
    }

    private func saveCorrection() {
        let saved = corrections.record(
            sessionId: session.id,
            originalText: correctionHeard,
            correctedText: correctionMeant,
            scope: correctionScope,
            source: .teaching
        )
        showCorrectionSheet = false
        guard saved != nil else { return }
        // Brief footer flash so the user gets feedback that their
        // correction landed. Same idiom as the Copy button.
        showTeachConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showTeachConfirmation = false
        }
    }

    private var correctionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Teach Humdrum")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "graduationcap")
                    .foregroundStyle(AppTheme.accent)
            }

            Text("Tell Humdrum what it should have heard. Saved corrections will be used to bias future transcripts toward the right word.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("What Humdrum heard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("e.g. \"see you at the meting\"", text: $correctionHeard, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What you actually said")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("e.g. \"see you at the meeting\"", text: $correctionMeant, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Apply this correction to")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                Picker("", selection: $correctionScope) {
                    ForEach(CorrectionScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Cancel") { showCorrectionSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save correction", action: saveCorrection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        correctionHeard.trimmingCharacters(in: .whitespaces).isEmpty ||
                        correctionMeant.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
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
