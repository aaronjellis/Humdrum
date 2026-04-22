import Foundation
import SwiftUI

// MARK: - Model

struct SessionSettings: Codable, Equatable {
    var quality: String                 // raw QualityLevel.rawValue
    var noiseFilter: String             // raw NoiseFilterLevel.rawValue
    var speakerLabelsEnabled: Bool
    var vocabularyHints: String
}

struct TranscriptSession: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var durationSeconds: Int
    var transcriptText: String
    var settings: SessionSettings

    var displayTitle: String {
        title.isEmpty ? Self.formattedDate(createdAt) : title
    }

    static func autoTitle(from text: String, fallback: Date) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return formattedDate(fallback) }
        // Strip leading "Speaker N: " if present.
        var stripped = trimmed
        if let range = stripped.range(of: "^Speaker\\s+\\d+:\\s*", options: .regularExpression) {
            stripped = String(stripped[range.upperBound...])
        }
        // Cap to one sentence or ~60 chars.
        if let endIdx = stripped.firstIndex(where: { ".?!\n".contains($0) }) {
            stripped = String(stripped[..<endIdx])
        }
        stripped = stripped.trimmingCharacters(in: .whitespaces)
        if stripped.count > 60 {
            stripped = String(stripped.prefix(60)) + "…"
        }
        return stripped.isEmpty ? formattedDate(fallback) : stripped
    }

    static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [TranscriptSession] = []

    private let directory: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let root = appSupport.appendingPathComponent("Humdrum", isDirectory: true)

        // One-time migration from the old "MeetingScribe" folder so users
        // who recorded under the previous name don't see their session
        // history disappear after the rebuild. The moveItem call is a
        // no-op if the old folder doesn't exist or the new one is
        // already populated.
        let legacy = appSupport.appendingPathComponent("MeetingScribe", isDirectory: true)
        if fm.fileExists(atPath: legacy.path),
           !fm.fileExists(atPath: root.path) {
            try? fm.moveItem(at: legacy, to: root)
        }

        let dir = root.appendingPathComponent("sessions", isDirectory: true)
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

        var loaded: [TranscriptSession] = []
        for file in entries where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let session = try? decoder.decode(TranscriptSession.self, from: data) {
                loaded.append(session)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        sessions = loaded
    }

    func save(_ session: TranscriptSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(session)
            try data.write(to: url(for: session.id), options: .atomic)
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = session
            } else {
                sessions.insert(session, at: 0)
            }
            sessions.sort { $0.createdAt > $1.createdAt }
        } catch {
            NSLog("SessionStore: save failed: \(error)")
        }
    }

    func delete(_ session: TranscriptSession) {
        try? FileManager.default.removeItem(at: url(for: session.id))
        sessions.removeAll { $0.id == session.id }
    }

    func session(with id: UUID) -> TranscriptSession? {
        sessions.first(where: { $0.id == id })
    }
}

// MARK: - Selection

/// Which pane the detail area should show.
enum SessionSelection: Equatable, Hashable {
    case newSession
    case session(UUID)
}

// MARK: - Save format

/// Export format for transcripts. User picks a default in Settings; the
/// Save dialog also offers all four and respects whatever the user
/// picks at save time.
enum SaveFormat: String, CaseIterable, Codable, Identifiable {
    case txt
    case md
    case rtf
    case json

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .txt:  return "Plain text (.txt)"
        case .md:   return "Markdown (.md)"
        case .rtf:  return "Rich text (.rtf)"
        case .json: return "JSON (.json)"
        }
    }

    var shortLabel: String {
        switch self {
        case .txt:  return ".txt"
        case .md:   return ".md"
        case .rtf:  return ".rtf"
        case .json: return ".json"
        }
    }

    var description: String {
        switch self {
        case .txt:  return "Plain text, no formatting — universal."
        case .md:   return "Title, metadata, and bolded speaker labels. Great for Obsidian / GitHub / Notion."
        case .rtf:  return "Rich text with bold speakers. Opens in Word, Pages, TextEdit with styling intact."
        case .json: return "Structured data with metadata. Useful for programmatic pipelines."
        }
    }
}
