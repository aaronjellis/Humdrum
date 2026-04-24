import Foundation

/// Post-decode cleanup for Whisper's known-hallucination phrases.
///
/// Whisper, during silent audio windows, loves to emit "Thanks for
/// watching." or "Subtitles by the amara.org community" — both are
/// artifacts of its YouTube training data and are never what the user
/// actually said. We drop them when *the entire transcript slice* is
/// one of these phrases; we deliberately do not pattern-match substrings
/// because a real sentence like "She said thanks." should survive.
///
/// Lives in HumdrumCore so the list + matcher can be unit-tested
/// independently of the live transcription pipeline.
public enum NoiseSanitizer {

    /// Exact lowercase matches that get dropped (returned as `""`) when
    /// `level != .off`. Matching is performed after trimming whitespace.
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

    /// Return `raw` trimmed, unless `level != .off` and the trimmed +
    /// lowercased value is a known hallucination — in which case return
    /// `""`. `nil` input returns `""`.
    public static func sanitize(_ raw: String?, level: NoiseFilterLevel) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if level == .off { return t }
        if bannedExactPhrases.contains(t.lowercased()) { return "" }
        return t
    }
}
