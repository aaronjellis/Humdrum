import Foundation

/// Post-decode cleanup for Whisper's known-hallucination phrases and its
/// non-speech sound annotations.
///
/// Two distinct artifacts get cleaned here, both only when
/// `level != .off`:
///
///   1. Whole-utterance hallucinations. During silent audio windows
///      Whisper loves to emit "Thanks for watching." or "Subtitles by
///      the amara.org community" — artifacts of its YouTube training
///      data, never what the user said. We drop them when *the entire
///      transcript slice* is one of these phrases; we deliberately do
///      not pattern-match substrings because a real sentence like
///      "She said thanks." should survive.
///
///   2. Non-speech sound annotations. Whisper wraps sound events it
///      hears but can't transcribe as words — `[BACKGROUND NOISE]`,
///      `[BLANK_AUDIO]`, `[Music]`, `(coughing)`, `♪` — in brackets,
///      parentheses, or music notes. In a dictation context these are
///      never spoken words the user wants pasted into their document,
///      so we strip them *inline* (anywhere in the slice, not just when
///      they're the whole thing). Square-bracket and music-note spans
///      are stripped unconditionally — a user dictating into a text
///      field practically never says "open bracket." Parenthetical
///      spans are stripped only when they read as a sound descriptor
///      (so a genuine dictated aside like "(call me back)" survives).
///
/// Lives in HumdrumCore so the list + matcher can be unit-tested
/// independently of the live transcription pipeline.
public enum NoiseSanitizer {

    /// Exact lowercase matches that get dropped (returned as `""`) when
    /// `level != .off`. Matching is performed after trimming whitespace
    /// and after inline annotations have been stripped.
    public static let bannedExactPhrases: Set<String> = [
        "thanks for watching.",
        "thanks for watching!",
        "thank you for watching.",
        "thank you for watching!",
        "thank you.",
        "thanks.",
        "please subscribe.",
        "subtitles by the amara.org community",
        "you",
        ".",
        "♪",
        "[music]",
        "[silence]",
        "(music)",
        "(silence)",
    ]

    /// Lowercased descriptor words that mark a *parenthetical* span as a
    /// non-speech sound annotation rather than a dictated aside. A
    /// `(…)` span is stripped only when it's short (≤ 3 words) and one
    /// of its words is in this set — that keeps "(upbeat music)" and
    /// "(coughing)" out of the transcript while leaving a real aside
    /// like "(I'll send the deck tomorrow)" untouched. Square-bracket
    /// spans don't consult this list; they're always Whisper
    /// annotations and are stripped wholesale.
    static let nonSpeechDescriptors: Set<String> = [
        "music", "silence", "noise", "blank_audio", "audio", "inaudible",
        "applause", "laughter", "laughs", "laughing", "coughing", "cough",
        "coughs", "sighs", "sigh", "typing", "static", "beep", "beeping",
        "ringing", "footsteps", "breathing", "pause", "crosstalk",
        "chuckles", "chuckling", "sniffs", "clicking", "humming",
        "buzzing", "indistinct", "muffled", "whispering", "sneezes",
        "background", "chatter", "rustling", "wind", "clears", "throat",
    ]

    /// Return `raw` trimmed and stripped of non-speech annotations,
    /// unless `level == .off` (pure passthrough) — in which case the raw
    /// trimmed value is returned verbatim, annotations and all. When the
    /// filter is on and the post-strip result is empty or a known
    /// whole-utterance hallucination, returns `""`. `nil` input returns
    /// `""`.
    public static func sanitize(_ raw: String?, level: NoiseFilterLevel) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if level == .off { return trimmed }

        // Drop Whisper's inline sound annotations, then collapse the
        // whitespace they leave behind (e.g. "Intro [Music] then" →
        // "Intro  then" → "Intro then").
        let stripped = collapseWhitespace(stripNonSpeechAnnotations(trimmed))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }

        if bannedExactPhrases.contains(stripped.lowercased()) { return "" }
        return stripped
    }

    /// Removes Whisper non-speech annotation spans from anywhere in
    /// `text`: every `[…]` span, every `♪…♪` (and stray `♪`) span, and
    /// any `(…)` span that reads as a sound descriptor. Exposed
    /// internally so the behavior can be unit-tested directly.
    static func stripNonSpeechAnnotations(_ text: String) -> String {
        var out = text

        // Square brackets: always an annotation in a dictation context.
        out = out.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: " ",
            options: .regularExpression
        )

        // Music-note spans and any stray notes.
        out = out.replacingOccurrences(
            of: "♪[^♪]*♪",
            with: " ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: "♪", with: " ")

        // Parentheses: strip only descriptor-looking spans.
        out = stripDescriptorParentheticals(out)

        return out
    }

    /// Walks `text` and removes each `(…)` span whose inner content is a
    /// short sound descriptor (≤ 3 words, at least one of them in
    /// `nonSpeechDescriptors`). Anything that doesn't match — a real
    /// dictated aside, a long parenthetical — is left in place.
    private static func stripDescriptorParentheticals(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\(([^)]*)\\)") else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        )
        for match in matches {
            let full = match.range
            let inner = ns.substring(with: match.range(at: 1))
            result += ns.substring(with: NSRange(location: lastEnd, length: full.location - lastEnd))
            if !isSoundDescriptor(inner) {
                // Keep the span verbatim.
                result += ns.substring(with: full)
            } else {
                result += " "
            }
            lastEnd = full.location + full.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    /// True when the parenthetical content reads as a Whisper sound
    /// annotation: short, and built out of descriptor words.
    private static func isSoundDescriptor(_ inner: String) -> Bool {
        let words = inner
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.contains { nonSpeechDescriptors.contains($0) }
    }

    /// Collapses runs of whitespace (left behind by stripped spans) into
    /// single spaces, and tidies a space that now sits before sentence
    /// punctuation (e.g. "word ." → "word.").
    private static func collapseWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "\\s+([.,!?;:])",
            with: "$1",
            options: .regularExpression
        )
        return out
    }
}
