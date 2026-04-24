import Foundation

/// Splits a string into UTF-16 chunks suitable for
/// `CGEventKeyboardSetUnicodeString`, which in practice can only carry
/// ~20 UTF-16 code units per event on macOS before some apps start
/// dropping the tail end silently.
///
/// Why this is worth its own file (and test target): the naive
/// implementation — `Array(text.utf16).chunked(by: 20)` — will slice
/// through the middle of a surrogate pair if an emoji straddles a
/// boundary. The result is that, e.g., "🎉" becomes `D83C` in one event
/// and `DF89` in the next, and some apps render the first half as a
/// replacement glyph before the second half arrives. Keeping surrogate
/// pairs intact at chunk boundaries is the only practical fix.
public enum TextChunker {

    /// Default chunk size used by the dictation paste path. Chosen to
    /// stay well under the observed safe limit of `CGEvent`'s unicode
    /// payload. Tunable for testing.
    public static let defaultKeystrokeChunkSize = 20

    /// Split `text` into UTF-16 chunks no larger than `chunkSize`,
    /// guaranteeing that surrogate pairs are never split between chunks.
    ///
    /// Behavior:
    ///   • Empty input → empty array.
    ///   • `chunkSize <= 0` → a single chunk containing the full string
    ///     (defensive: this is a programmer error, but we'd rather ship
    ///     the text than crash).
    ///   • Surrogate pair at a boundary → pulled into the *next* chunk
    ///     so the current chunk stays at most `chunkSize - 1`.
    ///     (Pushing into the current chunk would mean `chunkSize + 1`,
    ///     which is exactly the failure mode we're guarding against.)
    public static func utf16Chunks(
        for text: String,
        chunkSize: Int = defaultKeystrokeChunkSize
    ) -> [[UInt16]] {
        if text.isEmpty { return [] }
        let units = Array(text.utf16)
        if chunkSize <= 0 { return [units] }

        var result: [[UInt16]] = []
        var index = 0
        while index < units.count {
            var end = min(index + chunkSize, units.count)

            // If we're about to split a surrogate pair, pull the high
            // surrogate back out so the pair goes into the next chunk
            // intact. High surrogates live in 0xD800...0xDBFF.
            if end < units.count {
                let last = units[end - 1]
                if (0xD800...0xDBFF).contains(last) {
                    end -= 1
                    // Edge case: a chunkSize of 1 with a surrogate at
                    // position 0 would produce an empty chunk. Guard.
                    if end == index {
                        // No progress possible without splitting the
                        // pair — take both halves together. The chunk
                        // overshoots by 1 unit, which is still safer
                        // than emitting a lone high surrogate.
                        end = min(index + 2, units.count)
                    }
                }
            }

            result.append(Array(units[index..<end]))
            index = end
        }
        return result
    }
}
