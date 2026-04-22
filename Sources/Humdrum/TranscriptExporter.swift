import Foundation
import AppKit

/// Single source of truth for turning a `TranscriptSession` into file
/// contents in any of the four supported formats. Both the Save…
/// dialog in `SessionDetailView` and the auto-save-on-record-end hook
/// in `AppState` call through here so plain-text / Markdown / RTF /
/// JSON output stays byte-for-byte identical between the two paths.
enum TranscriptExporter {

    // MARK: - Public API

    /// Returns the serialized bytes for a session in the requested
    /// format. Writing to disk is the caller's responsibility.
    static func data(for session: TranscriptSession, format: SaveFormat) -> Data {
        switch format {
        case .txt:
            return Data(session.transcriptText.utf8)
        case .md:
            return Data(markdown(for: session).utf8)
        case .rtf:
            return rtf(for: session)
        case .json:
            return Data(json(for: session).utf8)
        }
    }

    /// Writes the serialized bytes to `url`, atomically. Throws any
    /// filesystem error so callers can surface it in an alert.
    static func write(
        session: TranscriptSession,
        format: SaveFormat,
        to url: URL
    ) throws {
        try data(for: session, format: format).write(to: url, options: [.atomic])
    }

    /// Builds a sanitized default filename for a session in the form
    /// `{title}-{YYYY-MM-DD-HHmm}.{ext}`. Used both by the Save panel
    /// and by the auto-save path.
    static func defaultFilename(for session: TranscriptSession, format: SaveFormat) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let base = session.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(base)-\(f.string(from: session.createdAt)).\(format.fileExtension)"
    }

    /// Picks a non-colliding URL inside `folder` for `session`/`format`.
    /// Appends `-1`, `-2`, … before the extension if the desired name
    /// already exists. Used by the auto-save path so two back-to-back
    /// dictations never silently overwrite one another.
    static func uniqueAutosaveURL(
        for session: TranscriptSession,
        format: SaveFormat,
        in folder: URL
    ) -> URL {
        let name = defaultFilename(for: session, format: format)
        var candidate = folder.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = format.fileExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 1
        while i < 1000 {
            candidate = folder.appendingPathComponent("\(stem)-\(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
        return candidate
    }

    // MARK: - Format renderers

    /// Markdown with a title, metadata line, and bolded "Speaker N:"
    /// prefixes on each paragraph. Great for Obsidian / Notion / GitHub.
    static func markdown(for session: TranscriptSession) -> String {
        var md = "# \(session.displayTitle)\n\n"

        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        let date = f.string(from: session.createdAt)
        let d = session.durationSeconds
        let duration = String(format: "%d:%02d", d / 60, d % 60)

        md += "_\(date) · \(duration) · "
        md += "Quality: \(session.settings.quality.capitalized), "
        md += "Noise filter: \(session.settings.noiseFilter.capitalized)_\n\n"
        md += "---\n\n"

        let paragraphs = session.transcriptText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for p in paragraphs {
            let withBoldLabel = p.replacingOccurrences(
                of: #"^(Speaker\s+\d+):"#,
                with: "**$1:**",
                options: .regularExpression
            )
            md += "\(withBoldLabel)\n\n"
        }

        return md
    }

    /// Rich text — title, metadata, bolded "Speaker N:" labels.
    /// Opens in Word / Pages / TextEdit with styling preserved.
    static func rtf(for session: TranscriptSession) -> Data {
        let out = NSMutableAttributedString()

        out.append(.init(
            string: session.displayTitle + "\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 20)]
        ))

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let d = session.durationSeconds
        let durationStr = String(format: "%d:%02d", d / 60, d % 60)
        let metaLine = "\(dateFormatter.string(from: session.createdAt)) · \(durationStr) · "
            + "Quality: \(session.settings.quality.capitalized), "
            + "Noise filter: \(session.settings.noiseFilter.capitalized)\n\n"
        out.append(.init(
            string: metaLine,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))

        let bodyFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        let paragraphs = session.transcriptText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let speakerRegex = try? NSRegularExpression(pattern: #"^(Speaker\s+\d+:)\s*"#)

        for (idx, paragraph) in paragraphs.enumerated() {
            if let regex = speakerRegex,
               let match = regex.firstMatch(
                   in: paragraph,
                   range: NSRange(location: 0, length: paragraph.utf16.count)
               ),
               let labelRange = Range(match.range(at: 1), in: paragraph) {
                let label = String(paragraph[labelRange])
                let rest = paragraph[labelRange.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                out.append(.init(string: label + " ", attributes: [.font: boldFont]))
                out.append(.init(string: rest, attributes: [.font: bodyFont]))
            } else {
                out.append(.init(string: paragraph, attributes: [.font: bodyFont]))
            }
            if idx < paragraphs.count - 1 {
                out.append(.init(string: "\n\n", attributes: [.font: bodyFont]))
            }
        }

        return out.rtf(
            from: NSRange(location: 0, length: out.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) ?? Data()
    }

    /// JSON with metadata + transcript for programmatic pipelines.
    static func json(for session: TranscriptSession) -> String {
        struct Export: Codable {
            let title: String
            let createdAt: String
            let durationSeconds: Int
            let transcript: String
            let settings: Settings
            struct Settings: Codable {
                let quality: String
                let noiseFilter: String
                let speakerLabelsEnabled: Bool
                let vocabularyHints: String
            }
        }
        let iso = ISO8601DateFormatter()
        let export = Export(
            title: session.displayTitle,
            createdAt: iso.string(from: session.createdAt),
            durationSeconds: session.durationSeconds,
            transcript: session.transcriptText,
            settings: Export.Settings(
                quality: session.settings.quality,
                noiseFilter: session.settings.noiseFilter,
                speakerLabelsEnabled: session.settings.speakerLabelsEnabled,
                vocabularyHints: session.settings.vocabularyHints
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(export),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
