import Foundation
import SwiftUI

// MARK: - Correction model
//
// One correction = one user-confirmed mismatch between what Humdrum heard
// and what the speaker actually meant. Tonight's slice only persists this
// one shape — the substitution engine, phonetic anchors, vocabulary
// seeds, and negative examples land in subsequent evenings as the
// learning loop expands. Schema is deliberately stable from day one so
// later phases can read existing corrections without a migration.
//
// Persistence: JSON files at
//   ~/Library/Application Support/Humdrum/corrections/{uuid}.json
// matching `SessionStore`'s pattern. Switching to GRDB later is a
// straightforward import job — every field on `Correction` maps 1:1 to
// a column in the planned schema.

/// Where this correction should apply when the substitution engine eventually
/// reads them. `global` = anywhere in any future transcript; `session` =
/// only inside its originating session (handy for one-off proper nouns
/// the user doesn't want bleeding into other meetings); `sender` =
/// scoped to a recognized speaker (unused tonight; defined here so the
/// shape doesn't churn when diarization-aware corrections land).
enum CorrectionScope: String, Codable, CaseIterable, Identifiable {
    case global
    case session
    case sender

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global:  return "Always"
        case .session: return "This recording only"
        case .sender:  return "This speaker"
        }
    }
}

/// Provenance of a correction. Maps directly to confidence weights when
/// substitutions get applied: a correction the user typed under "Teach
/// Humdrum" is more reliable than one passively scraped from a mid-edit
/// because the user explicitly intended it as feedback.
///
/// Weights match the STARTER_PLAN spec:
///   • passive       — 0.85 (user edited a transcript; we inferred a fix)
///   • teaching      — 0.95 (user opened the correction sheet on purpose)
///   • pronounceIt   — 0.99 (user spoke the word in isolation for us)
enum CorrectionSource: String, Codable, CaseIterable {
    case passive
    case teaching
    case pronounceIt

    var defaultWeight: Double {
        switch self {
        case .passive:     return 0.85
        case .teaching:    return 0.95
        case .pronounceIt: return 0.99
        }
    }
}

struct Correction: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date
    /// The session this correction was filed against. Optional because
    /// a future "I want to teach Humdrum a name without recording first"
    /// flow won't have one.
    var sessionId: UUID?
    /// Exactly what Whisper produced — the string the user double-clicked.
    var originalText: String
    /// What the speaker actually meant.
    var correctedText: String
    /// The phrase Whisper produced immediately before `originalText`,
    /// up to ~3 words. Lets the substitution engine disambiguate
    /// homographs ("Lee" the name vs. "Lee" in "Lee surprised me").
    /// Optional — empty when the corrected token is at the start of the
    /// transcript.
    var contextBefore: String?
    /// Same idea, the words after.
    var contextAfter: String?
    /// Where this correction should apply going forward.
    var scope: CorrectionScope
    /// How sure we should be that the user really meant this. Set from
    /// `source.defaultWeight` at create time, but stored as a Double so
    /// future tooling can decay or reinforce confidence over time
    /// without losing the original signal.
    var weight: Double
    /// How the correction was captured — drives weight defaults and
    /// surface-specific UX later (e.g. "Pronounce it for me" needs
    /// audio capture).
    var source: CorrectionSource
}

// MARK: - Store
//
// JSON-per-correction so a single bad encode can't take out the whole
// learning history (same trade-off SessionStore makes). Lookups are by
// pattern matching `originalText` + context, which the substitution
// engine will do in-memory off the published `corrections` array.

@MainActor
final class CorrectionsStore: ObservableObject {

    @Published private(set) var corrections: [Correction] = []

    private let directory: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let root = appSupport.appendingPathComponent("Humdrum", isDirectory: true)
        let dir = root.appendingPathComponent("corrections", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        loadAll()
    }

    // MARK: Persistence

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadAll() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [Correction] = []
        for file in entries where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let c = try? decoder.decode(Correction.self, from: data) {
                loaded.append(c)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        corrections = loaded
        Diagnostics.learning.info("corrections.load count=\(loaded.count)")
    }

    /// Persist a correction. Same pattern as SessionStore — atomic
    /// write, in-memory list updated immediately so any observing UI
    /// re-renders without waiting on disk.
    @discardableResult
    func record(
        sessionId: UUID?,
        originalText: String,
        correctedText: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        scope: CorrectionScope = .global,
        source: CorrectionSource = .teaching
    ) -> Correction? {
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty,
              !corrected.isEmpty,
              original != corrected else {
            return nil
        }

        let correction = Correction(
            createdAt: Date(),
            sessionId: sessionId,
            originalText: original,
            correctedText: corrected,
            contextBefore: contextBefore?.trimmingCharacters(in: .whitespaces),
            contextAfter: contextAfter?.trimmingCharacters(in: .whitespaces),
            scope: scope,
            weight: source.defaultWeight,
            source: source
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(correction)
            try data.write(to: url(for: correction.id), options: .atomic)
            corrections.insert(correction, at: 0)
            Diagnostics.learning.info(
                "correction.recorded source=\(source.rawValue, privacy: .public) scope=\(scope.rawValue, privacy: .public) origLen=\(original.count) corrLen=\(corrected.count)"
            )
            return correction
        } catch {
            Diagnostics.learning.error("correction.save.failed err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Remove a correction by id. Used by the Settings → Learning panel
    /// when the user wants to revoke something they taught Humdrum
    /// earlier (a phase β surface — wired now so the data layer is
    /// complete).
    func revoke(_ correction: Correction) {
        try? FileManager.default.removeItem(at: url(for: correction.id))
        corrections.removeAll { $0.id == correction.id }
        Diagnostics.learning.info("correction.revoked id=\(correction.id.uuidString, privacy: .public)")
    }

    /// All corrections that target this session — useful for showing a
    /// "this session has 3 corrections" badge or for replaying them
    /// when re-rendering the transcript with substitutions applied.
    func corrections(for sessionId: UUID) -> [Correction] {
        corrections.filter { $0.sessionId == sessionId }
    }
}
