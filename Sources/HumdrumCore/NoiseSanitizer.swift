import Foundation

/// Post-decode cleanup for Whisper's known-hallucination output.
///
/// Whisper, during silent or non-speech audio windows, emits two kinds
/// of junk the user never said:
///
///   1. Training-data phrases ("Thanks for watching.", "Subtitles by
///      the amara.org community") — dropped only when the *entire*
///      transcript slice is one of these, because a real sentence like
///      "She said thanks." must survive.
///   2. Non-speech annotation tags ("[BLANK_AUDIO]", "[Music]",
///      "(laughing)", "♪") — stripped wherever they appear. Whisper
///      only emits square-bracketed spans for annotations, never for
///      spoken words, so any `[...]` span is removed. Parenthesized
///      spans could in principle wrap real words, so they are removed
///      only when the content matches a known annotation vocabulary.
///
/// Lives in HumdrumCore so the lists + matcher can be unit-tested
/// independently of the live transcription pipeline.
public enum NoiseSanitizer {

    /// Exact lowercase matches that get dropped (returned as `""`) when
    /// `level != .off` and the entire trimmed slice equals the phrase.
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

    /// Lowercased, underscore-normalized inner content that marks a
    /// parenthesized span as a non-speech annotation. Square-bracketed
    /// spans are stripped unconditionally and don't consult this list.
    public static let noiseAnnotationContents: Set<String> = [
        "music", "silence", "blank audio", "no audio", "no speech",
        "applause", "laughter", "laughing", "laughs", "chuckles",
        "chuckling", "giggles", "giggling", "cough", "coughs", "coughing",
        "clears throat", "throat clearing", "sigh", "sighs", "sighing",
        "breathing", "breathes", "sniffs", "sniffles", "sniffing",
        "typing", "keyboard clicking", "clicking", "click", "static",
        "noise", "background noise", "inaudible", "indistinct",
        "unintelligible", "muffled", "pause", "beep", "beeping", "bell",
        "chatter", "crosstalk", "wind", "hums", "humming", "whistling",
        "phone ringing", "ringing", "footsteps", "door closes",
        "door opens", "snoring", "yawns", "yawning", "groans", "grunts",
        "gasps", "whispers", "whispering", "screams", "screaming",
    ]

    /// Return `raw` trimmed, unless `level != .off`, in which case:
    /// whole-slice hallucination phrases return `""`, and non-speech
    /// annotation tags are stripped wherever they appear (a slice that
    /// was *only* tags therefore also returns `""`). `nil` input
    /// returns `""`. When `level == .off` the trimmed input passes
    /// through untouched, tags and all.
    public static func sanitize(_ raw: String?, level: NoiseFilterLevel) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if level == .off { return t }
        if bannedExactPhrases.contains(t.lowercased()) { return "" }
        let stripped = strippingAnnotations(t)
        if bannedExactPhrases.contains(stripped.lowercased()) { return "" }
        return stripped
    }

    /// Remove non-speech annotation spans anywhere in `text` and
    /// collapse the whitespace the removals open up.
    static func strippingAnnotations(_ text: String) -> String {
        var s = text
        // Whisper only square-brackets annotations ([BLANK_AUDIO],
        // [Music], [inaudible]) — never spoken words.
        s = s.replacing(#/\[[^\[\]]*\]/#, with: " ")
        // Parens are annotation-only in practice too, but stay
        // vocabulary-gated in case real words ever get wrapped.
        s = s.replacing(#/\(([^()]*)\)/#) { match in
            let inner = normalizeAnnotation(match.output.1)
            return inner.isEmpty || noiseAnnotationContents.contains(inner) ? " " : String(match.output.0)
        }
        s = s.replacing(#/[♪♫]+/#, with: " ")
        // Collapse the whitespace runs opened up by the removals and trim.
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalizeAnnotation(_ inner: Substring) -> String {
        inner.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
