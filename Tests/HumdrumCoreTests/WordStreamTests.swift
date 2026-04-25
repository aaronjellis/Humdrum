import XCTest
@testable import HumdrumCore

/// Tests for `WordStream` — the monotonic, prefix-stable feed that
/// drives the dictation orb's word ticker. The properties that matter:
///
///   • IDs are monotonic per session and never reused, so the view
///     layer can `.id(word.id)` for stable animation identity.
///   • Repeated tokens (`"the the the"`) produce three distinct words.
///     This is the property the obvious-but-wrong "dedup by text"
///     implementation breaks.
///   • Whisper rewriting the *trailing* portion of confirmed text
///     keeps the stable prefix's IDs intact and re-emits only the
///     suffix with fresh IDs.
///   • `reset()` clears state — both the buffer and the next-id
///     counter — so back-to-back dictation sessions don't leak IDs
///     into each other.
///
/// Pure-logic; no clocks, no Combine — the caller supplies `now`.
final class WordStreamTests: XCTestCase {

    // A fixed reference clock so test assertions on `bornAt` are
    // exact rather than approximate.
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Empty / no-op

    func testEmptyStringProducesNoWords() {
        var stream = WordStream()
        let appended = stream.ingest(confirmed: "", now: t0)
        XCTAssertEqual(appended, [])
        XCTAssertEqual(stream.words, [])
    }

    func testWhitespaceOnlyProducesNoWords() {
        var stream = WordStream()
        let appended = stream.ingest(confirmed: "   \n\t  ", now: t0)
        XCTAssertEqual(appended, [])
        XCTAssertEqual(stream.words, [])
    }

    // MARK: - Monotonic append on growing confirmed text

    func testMonotonicAppendOnGrowingText() {
        var stream = WordStream()

        let first = stream.ingest(confirmed: "hello", now: t0)
        XCTAssertEqual(first.map(\.text), ["hello"])
        XCTAssertEqual(first.map(\.id), [0])

        let second = stream.ingest(confirmed: "hello world", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(second.map(\.text), ["world"])
        XCTAssertEqual(second.map(\.id), [1])

        let third = stream.ingest(confirmed: "hello world how are you", now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(third.map(\.text), ["how", "are", "you"])
        XCTAssertEqual(third.map(\.id), [2, 3, 4])

        XCTAssertEqual(stream.words.map(\.text), ["hello", "world", "how", "are", "you"])
        XCTAssertEqual(stream.words.map(\.id), [0, 1, 2, 3, 4])
    }

    func testReingestingTheSameTextProducesNoNewWords() {
        // Two consecutive Combine fires on the same confirmed string
        // — common when other publishers tick on the manager — must
        // not produce phantom duplicate StreamedWords.
        var stream = WordStream()
        _ = stream.ingest(confirmed: "hello world", now: t0)
        let again = stream.ingest(confirmed: "hello world", now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(again, [])
        XCTAssertEqual(stream.words.map(\.id), [0, 1])
    }

    func testBornAtIsRecordedAtIngestTime() {
        var stream = WordStream()
        _ = stream.ingest(confirmed: "alpha", now: t0)
        _ = stream.ingest(confirmed: "alpha beta", now: t0.addingTimeInterval(0.5))

        XCTAssertEqual(stream.words[0].bornAt, t0)
        XCTAssertEqual(stream.words[1].bornAt, t0.addingTimeInterval(0.5))
    }

    // MARK: - Repeated words

    func testRepeatedWordsAreDistinctEntries() {
        // "the the the" is a perfectly normal piece of dictated speech
        // — fillers, false starts, etc. The ticker must show three
        // separate words (not collapse to one), so each repetition
        // gets its own monotonic ID.
        var stream = WordStream()
        let appended = stream.ingest(confirmed: "the the the", now: t0)
        XCTAssertEqual(appended.count, 3)
        XCTAssertEqual(appended.map(\.id), [0, 1, 2])
        XCTAssertEqual(appended.map(\.text), ["the", "the", "the"])
        XCTAssertEqual(Set(appended.map(\.id)).count, 3)
    }

    func testRepeatedWordsAcrossIngestsAreDistinct() {
        var stream = WordStream()
        _ = stream.ingest(confirmed: "uh", now: t0)
        let second = stream.ingest(confirmed: "uh uh", now: t0.addingTimeInterval(0.3))
        let third = stream.ingest(confirmed: "uh uh uh", now: t0.addingTimeInterval(0.6))

        XCTAssertEqual(second.map(\.id), [1])
        XCTAssertEqual(third.map(\.id), [2])
        XCTAssertEqual(stream.words.map(\.id), [0, 1, 2])
    }

    // MARK: - Prefix-stable rewrite

    func testWhisperTailRewriteKeepsPrefixIDsStable() {
        // Whisper often refines the last word as more audio comes in:
        // "I went to the stoor" → "I went to the store". The first four
        // words must keep their IDs (already animating in the ticker);
        // only "store" gets a fresh ID, replacing "stoor" in the
        // canonical buffer.
        var stream = WordStream()
        _ = stream.ingest(confirmed: "I went to the stoor", now: t0)
        let beforeIDs = stream.words.map(\.id)
        XCTAssertEqual(beforeIDs, [0, 1, 2, 3, 4])

        let appended = stream.ingest(confirmed: "I went to the store", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.text, "store")
        XCTAssertEqual(appended.first?.id, 5)  // monotonic, fresh

        XCTAssertEqual(stream.words.map(\.text), ["I", "went", "to", "the", "store"])
        XCTAssertEqual(stream.words.map(\.id), [0, 1, 2, 3, 5])
    }

    func testWhisperRewritesMultipleTrailingWords() {
        var stream = WordStream()
        _ = stream.ingest(confirmed: "the cat sat on", now: t0)
        let appended = stream.ingest(confirmed: "the cat is happy now", now: t0.addingTimeInterval(0.5))

        // Stable prefix is "the cat" — IDs 0,1 unchanged.
        // "sat on" was tail-rewritten to "is happy now"; three fresh IDs.
        XCTAssertEqual(appended.map(\.text), ["is", "happy", "now"])
        XCTAssertEqual(appended.map(\.id), [4, 5, 6])
        XCTAssertEqual(stream.words.map(\.text), ["the", "cat", "is", "happy", "now"])
        XCTAssertEqual(stream.words.map(\.id), [0, 1, 4, 5, 6])
    }

    func testRewriteEntireConfirmedTextEmitsAllNew() {
        // Pathological case — Whisper revises everything. Every ID is
        // fresh; no token from the old buffer survives.
        var stream = WordStream()
        _ = stream.ingest(confirmed: "alpha bravo", now: t0)
        let appended = stream.ingest(confirmed: "charlie delta", now: t0.addingTimeInterval(0.5))

        XCTAssertEqual(appended.map(\.text), ["charlie", "delta"])
        XCTAssertEqual(appended.map(\.id), [2, 3])
        XCTAssertEqual(stream.words.map(\.text), ["charlie", "delta"])
    }

    func testShorterConfirmedTextTrimsCanonicalBuffer() {
        // If confirmed shrinks (rare but possible during a model
        // refinement pass), the canonical buffer should match the new
        // shorter prefix. No words appended.
        var stream = WordStream()
        _ = stream.ingest(confirmed: "one two three four", now: t0)
        let appended = stream.ingest(confirmed: "one two", now: t0.addingTimeInterval(0.5))

        XCTAssertEqual(appended, [])
        XCTAssertEqual(stream.words.map(\.text), ["one", "two"])
        XCTAssertEqual(stream.words.map(\.id), [0, 1])
    }

    // MARK: - Reset

    func testResetClearsBufferAndIDCounter() {
        var stream = WordStream()
        _ = stream.ingest(confirmed: "alpha bravo charlie", now: t0)
        XCTAssertEqual(stream.words.count, 3)

        stream.reset()
        XCTAssertEqual(stream.words, [])

        // After reset the next session starts at id 0 again, not at
        // 3. Otherwise IDs grow unboundedly across the lifetime of
        // the app and the view layer's `.id(word.id)` keying becomes
        // unnecessarily noisy across session boundaries.
        let appended = stream.ingest(confirmed: "delta", now: t0.addingTimeInterval(10))
        XCTAssertEqual(appended.map(\.id), [0])
    }

    // MARK: - Whitespace handling

    func testCollapsesMultipleWhitespaceBetweenWords() {
        // Whisper occasionally emits double-spaces or stray newlines
        // between tokens. The tokenizer should treat any run of
        // whitespace as a single separator and not produce empty
        // tokens.
        var stream = WordStream()
        let appended = stream.ingest(confirmed: "hello   world\n\nfoo", now: t0)
        XCTAssertEqual(appended.map(\.text), ["hello", "world", "foo"])
        XCTAssertEqual(appended.map(\.id), [0, 1, 2])
    }

    func testLeadingAndTrailingWhitespaceProducesNoEmptyTokens() {
        var stream = WordStream()
        let appended = stream.ingest(confirmed: "   hello world   ", now: t0)
        XCTAssertEqual(appended.map(\.text), ["hello", "world"])
    }
}
