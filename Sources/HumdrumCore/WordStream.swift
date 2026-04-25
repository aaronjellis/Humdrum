import Foundation

/// A single word emitted into the dictation orb's word ticker. Each
/// word carries its own `id` and `bornAt` so the view layer can animate
/// it independently — sliding it from the right edge of the orb to the
/// left, fading as it goes — without losing track of which word is
/// which when Whisper rewrites the tail of the confirmed text.
///
/// We deliberately do *not* identify words by their text content.
/// Repeated words are a normal feature of spoken English ("like, like,
/// you know, the the the thing"), and dedup-by-text would visibly
/// misbehave by collapsing them in the ticker. Identity is by monotonic
/// sequence index, supplied by `WordStream`.
public struct StreamedWord: Identifiable, Equatable, Sendable {
    /// Monotonically increasing per dictation session. Reset on
    /// `WordStream.reset()`.
    public let id: Int
    public let text: String
    /// Wall-clock at the moment this word was first observed in the
    /// confirmed-text stream. The view layer uses `Date().timeIntervalSince(bornAt)`
    /// against a fixed `slideDuration` to compute the animation progress.
    public let bornAt: Date

    public init(id: Int, text: String, bornAt: Date) {
        self.id = id
        self.text = text
        self.bornAt = bornAt
    }
}

/// Append-only, prefix-stable feed of words derived from a Whisper
/// `confirmedText` stream. The contract is:
///
///   • Inputs (`confirmed: String`) are expected to grow monotonically
///     in the common case. Each call may append new tokens at the tail.
///   • Whisper occasionally rewrites the *trailing* portion of the
///     confirmed text as a later transcription pass refines a word.
///     When this happens we keep the longest stable prefix intact (those
///     `StreamedWord` IDs do not change) and re-emit the rewritten suffix
///     with fresh IDs.
///   • Words that disappear from the canonical buffer because of a
///     Whisper rewrite are *not* announced as deletions. The view layer
///     keeps a separate visual buffer (`visualWords` on the coordinator)
///     so already-fading words ride out their animation naturally; this
///     type only owns the canonical "what does the live transcript look
///     like right now" list.
///
/// Pure logic — no AppKit, no Combine, no clocks of its own. The
/// caller supplies `now` so tests can run deterministically.
public struct WordStream: Equatable, Sendable {

    public private(set) var words: [StreamedWord] = []
    private var nextId: Int = 0

    public init() {}

    /// Update the stream from a Whisper-style confirmed text and return
    /// the words that were *newly* appended this call. Words that the
    /// rewrite invalidated are removed from `words`; if the new tokens
    /// re-introduce the same text it gets fresh IDs (this is what lets
    /// the view layer fade out the old rendering and slide in the new
    /// one in parallel).
    @discardableResult
    public mutating func ingest(confirmed: String, now: Date) -> [StreamedWord] {
        let tokens = Self.tokenize(confirmed)

        // Find the longest stable prefix between the existing canonical
        // word list and the freshly-tokenized confirmed text. As soon as
        // they diverge — either Whisper rewrote a word or appended new
        // ones — we treat everything past that point as "new" relative
        // to the canonical list.
        var prefixLen = 0
        let cmp = min(words.count, tokens.count)
        while prefixLen < cmp && words[prefixLen].text == tokens[prefixLen] {
            prefixLen += 1
        }

        // Drop the stale tail from the canonical buffer. The view layer
        // keeps its own buffer (see file header) so already-animating
        // words finish their fade — we don't yank them off-screen.
        if prefixLen < words.count {
            words.removeSubrange(prefixLen...)
        }

        // Append newly-arrived tokens with fresh monotonic IDs. We use
        // `Array(tokens.dropFirst(prefixLen))` rather than slicing
        // directly so the indices in the loop are well-defined even if
        // the input had trailing whitespace.
        let appendedTokens = tokens.dropFirst(prefixLen)
        var appended: [StreamedWord] = []
        appended.reserveCapacity(appendedTokens.count)
        for token in appendedTokens {
            let word = StreamedWord(id: nextId, text: token, bornAt: now)
            nextId += 1
            words.append(word)
            appended.append(word)
        }
        return appended
    }

    /// Reset the canonical buffer and the monotonic ID counter. Call at
    /// the start of every new dictation session so IDs don't grow
    /// unboundedly across the lifetime of the app and so a fresh session
    /// can't collide with a previous session's leftover word IDs in the
    /// view layer's keying.
    public mutating func reset() {
        words.removeAll()
        nextId = 0
    }

    // MARK: - Tokenization
    //
    // Whitespace-split is good enough for dictation: Whisper emits text
    // with single spaces between words, and the ticker is a visual
    // affordance — perfect tokenization isn't required. We do filter
    // empty tokens so leading/trailing whitespace in the confirmed text
    // doesn't produce phantom empty words.

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}
