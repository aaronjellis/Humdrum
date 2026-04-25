import Foundation
import SwiftUI
import AppKit

/// Shared coordinator visible to every window.
///
/// Owns:
///  - `selection` — which session the main window is looking at
///  - The diarization worker — runs *off* of TranscriptionManager on
///    per-session audio snapshots, so new recordings can start while old
///    ones are still being labeled.
///
/// Flow:
///  1. Manager's `onSessionCompleted` hands us a self-contained
///     `TranscriptSessionSnapshot` (including audio + commits). The
///     manager has already reset its state at this point.
///  2. We persist the session with the no-speaker transcript, jump
///     `selection` to it so the UI shows it instantly.
///  3. If the user wanted speaker labels, we enqueue a diarization job
///     keyed by `session.id`. Jobs run in a serial task chain so we never
///     hammer FluidAudio with concurrent calls.
///  4. When a job finishes, we mutate that specific session in the store.
///     The SessionDetailView observes the store, so the transcript
///     updates in place.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published

    @Published var selection: SessionSelection = .newSession

    /// Sessions currently being diarized. Views use `isDiarizing(sessionId:)`
    /// to decide whether to show a "Analyzing voices…" spinner.
    @Published private(set) var diarizingSessionIds: Set<UUID> = []

    /// The folder the user has chosen to default transcript saves to.
    /// Nil → SessionDetailView's Save panel opens at the system default
    /// (usually Documents). Persisted to UserDefaults.
    @Published var defaultSaveFolderPath: String? {
        didSet {
            let defaults = UserDefaults.standard
            if let path = defaultSaveFolderPath, !path.isEmpty {
                defaults.set(path, forKey: Self.defaultSaveFolderKey)
            } else {
                defaults.removeObject(forKey: Self.defaultSaveFolderKey)
            }
        }
    }

    /// Convenience URL view of `defaultSaveFolderPath` for NSSavePanel.
    var defaultSaveFolderURL: URL? {
        guard let path = defaultSaveFolderPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Preferred file format for transcript saves. Used to pre-select
    /// the extension in NSSavePanel; the user can still pick a
    /// different one in the panel itself.
    @Published var defaultSaveFormat: SaveFormat {
        didSet {
            UserDefaults.standard.set(defaultSaveFormat.rawValue, forKey: Self.defaultSaveFormatKey)
        }
    }

    /// When true, completed recordings are written to
    /// `defaultSaveFolderPath` in `defaultSaveFormat` immediately after
    /// the in-app session is saved — no Save panel, no extra clicks.
    /// A no-op when no default folder is set, so turning this on without
    /// configuring a folder is safe (it just silently waits).
    @Published var autoSaveOnRecordEnd: Bool {
        didSet {
            UserDefaults.standard.set(autoSaveOnRecordEnd, forKey: Self.autoSaveOnRecordEndKey)
        }
    }

    /// The last file written by the auto-save path, if any. Used to
    /// show a short confirmation line in the detail view ("Saved to
    /// ~/Documents/Transcripts/foo.md") without the user having to dig
    /// for it in Finder.
    @Published private(set) var lastAutoSaveURL: URL?

    private static let defaultSaveFolderKey = "Humdrum.defaultSaveFolder"
    private static let defaultSaveFormatKey = "Humdrum.defaultSaveFormat"
    private static let autoSaveOnRecordEndKey = "Humdrum.autoSaveOnRecordEnd"

    init() {
        // Hydrate preferences up front so the very first Settings open
        // shows persisted values.
        let defaults = UserDefaults.standard
        self.defaultSaveFolderPath = defaults.string(forKey: Self.defaultSaveFolderKey)
        let storedFormat = defaults.string(forKey: Self.defaultSaveFormatKey)
        self.defaultSaveFormat = storedFormat.flatMap { SaveFormat(rawValue: $0) } ?? .txt
        // Default OFF — opt-in so a user who's never configured a
        // folder doesn't get surprised by files appearing somewhere.
        self.autoSaveOnRecordEnd =
            defaults.object(forKey: Self.autoSaveOnRecordEndKey) as? Bool ?? false
    }

    // MARK: - Private

    private weak var store: SessionStore?
    private let diarization = DiarizationService()
    private var lastDiarizationTask: Task<Void, Never>?

    // MARK: - Wire-up

    func wire(manager: TranscriptionManager, store: SessionStore) {
        self.store = store
        manager.onSessionCompleted = { [weak self] snap in
            self?.handleSessionCompleted(snap)
        }
    }

    // MARK: - Accessors

    func isDiarizing(sessionId: UUID) -> Bool {
        diarizingSessionIds.contains(sessionId)
    }

    // MARK: - Session lifecycle

    private func handleSessionCompleted(_ snap: TranscriptSessionSnapshot) {
        guard let store else { return }
        let trimmed = snap.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = TranscriptSession(
            title: TranscriptSession.autoTitle(from: snap.transcriptText, fallback: snap.createdAt),
            createdAt: snap.createdAt,
            durationSeconds: snap.durationSeconds,
            transcriptText: snap.transcriptText,
            settings: SessionSettings(
                quality: snap.quality,
                noiseFilter: snap.noiseFilter,
                speakerLabelsEnabled: snap.speakerLabelsEnabled,
                vocabularyHints: snap.vocabularyHints
            )
        )
        store.save(session)
        selection = .session(session.id)

        // Fire-and-forget auto-save to the user's chosen folder. Only
        // runs when the toggle is on AND a folder has been configured —
        // either being missing is a silent no-op, so you can turn the
        // toggle on before picking a folder (or vice versa) without
        // losing data.
        autoSaveIfEnabled(session: session)

        if snap.speakerLabelsEnabled,
           !snap.audioSamples.isEmpty,
           !snap.commits.isEmpty {
            // First-time consent: if the user has never downloaded the
            // FluidAudio models before, ask explicitly. If they cancel,
            // the transcript is saved without speaker labels — the
            // session still exists, just unlabeled.
            if !Self.diarizationConsented(), !promptDiarizationDownload() {
                return
            }
            enqueueDiarization(
                sessionId: session.id,
                audioSamples: snap.audioSamples,
                commits: snap.commits
            )
        }
    }

    // MARK: - Auto-save

    /// If the user has auto-save turned on AND picked a default folder,
    /// write the freshly-completed transcript there. Any failure is
    /// surfaced via a non-blocking alert so the user sees *why* the
    /// file didn't appear, rather than silently losing the output.
    private func autoSaveIfEnabled(session: TranscriptSession) {
        guard autoSaveOnRecordEnd else { return }
        guard let folder = defaultSaveFolderURL else { return }

        // Refuse empty transcripts — same rule as the detail view's
        // Save… button. The in-app session is already persisted;
        // writing a zero-byte file to the user's folder would be noise.
        guard !session.transcriptText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            autoSaveFailureAlert(
                reason: "The folder \(folder.path) no longer exists. "
                        + "Pick a new default folder in Settings → Transcripts."
            )
            return
        }

        let format = defaultSaveFormat
        let url = TranscriptExporter.uniqueAutosaveURL(
            for: session,
            format: format,
            in: folder
        )

        // Disk write happens off-main so a slow volume (SMB share,
        // spinning disk, network-mounted Dropbox folder) can't freeze
        // the UI for the second or two it takes to flush. The in-app
        // session is already saved at this point; this is only about
        // the side-car file in the user's chosen folder.
        Task.detached(priority: .utility) { [weak self] in
            do {
                try TranscriptExporter.write(session: session, format: format, to: url)
                await MainActor.run { [weak self] in
                    self?.lastAutoSaveURL = url
                }
            } catch {
                let reason = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.autoSaveFailureAlert(reason: reason)
                }
            }
        }
    }

    private func autoSaveFailureAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't auto-save transcript"
        alert.informativeText = reason
            + "\n\nThe transcript is still available in the app — just click Save… to save it manually."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings…")
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        }
    }

    // MARK: - Diarization download consent

    private static let consentKey = "Humdrum.diarization.consentedV1"

    private static func diarizationConsented() -> Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    private func promptDiarizationDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download speaker-diarization models?"
        alert.informativeText = """
            Labeling speakers needs ~80 MB of local voice-embedding models \
            (pyannote + WeSpeaker) from Hugging Face, saved to ~/Library/Caches. \
            One-time download, then runs entirely offline. \
            Skip to save the transcript without speaker labels.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "Skip speaker labels")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok { UserDefaults.standard.set(true, forKey: Self.consentKey) }
        return ok
    }

    // MARK: - Diarization worker (serial chain)

    private func enqueueDiarization(
        sessionId: UUID,
        audioSamples: [Float],
        commits: [TranscriptCommit]
    ) {
        diarizingSessionIds.insert(sessionId)

        // Chain after the previous job so FluidAudio isn't called twice
        // concurrently. The caller isn't blocked — new recordings and UI
        // interactions continue immediately.
        let previous = lastDiarizationTask
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.runDiarization(
                sessionId: sessionId,
                audioSamples: audioSamples,
                commits: commits
            )
        }
        lastDiarizationTask = task
    }

    private func runDiarization(
        sessionId: UUID,
        audioSamples: [Float],
        commits: [TranscriptCommit]
    ) async {
        defer {
            diarizingSessionIds.remove(sessionId)
        }

        do {
            let segments = try await diarization.diarize(
                samples: audioSamples,
                sampleRate: 16_000
            )

            // Renumber raw "speaker_N" IDs to "Speaker 1", "Speaker 2"…
            // in order of first appearance.
            var labeled = commits
            var idMap: [String: String] = [:]
            var nextNum = 1
            for i in labeled.indices {
                let c = labeled[i]
                guard let raw = DiarizationService.dominantSpeaker(
                    for: c.startTime, c.endTime, in: segments
                ) else {
                    labeled[i].speakerLabel = nil
                    continue
                }
                if let existing = idMap[raw] {
                    labeled[i].speakerLabel = existing
                } else {
                    let label = "Speaker \(nextNum)"
                    nextNum += 1
                    idMap[raw] = label
                    labeled[i].speakerLabel = label
                }
            }

            let text = renderText(from: labeled)
            applyDiarizedText(sessionId: sessionId, text: text)
        } catch {
            // Diarization failed — leave the speaker-less transcript in place.
            NSLog("Diarization failed: \(error)")
        }
    }

    private func applyDiarizedText(sessionId: UUID, text: String) {
        guard let store, var session = store.session(with: sessionId) else { return }
        session.transcriptText = text
        session.title = TranscriptSession.autoTitle(from: text, fallback: session.createdAt)
        store.save(session)
    }

    /// Builds a speaker-labeled transcript from labeled commits. Mirrors
    /// TranscriptionManager.renderConfirmedText but works on any `commits`
    /// array so the worker can format a session's text without touching
    /// manager state.
    private func renderText(from commits: [TranscriptCommit]) -> String {
        if commits.isEmpty { return "" }
        var out = ""
        var currentLabel: String? = "__none__"
        for c in commits {
            if c.speakerLabel != currentLabel {
                if !out.isEmpty { out += "\n\n" }
                if let label = c.speakerLabel {
                    out += "\(label): \(c.text)"
                } else {
                    out += c.text
                }
                currentLabel = c.speakerLabel
            } else {
                out += " " + c.text
            }
        }
        return out
    }
}
