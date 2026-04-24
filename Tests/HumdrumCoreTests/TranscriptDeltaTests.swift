import XCTest
@testable import HumdrumCore

/// Tests for the "what do I paste next?" diff. The divergence case is
/// the one that matters for correctness: if Whisper rewrites an earlier
/// commit, we must NOT keep pasting — otherwise the user sees their
/// original words AND the rewritten tail stacked together.
final class TranscriptDeltaTests: XCTestCase {

    // MARK: - Empty-state cases

    func testEmptyPastedReturnsFullConfirmed() {
        let result = TranscriptDelta.compute(
            confirmed: "hello world",
            alreadyPasted: ""
        )
        XCTAssertEqual(result, "hello world")
    }

    func testEmptyConfirmedReturnsEmpty() {
        let result = TranscriptDelta.compute(
            confirmed: "",
            alreadyPasted: ""
        )
        XCTAssertEqual(result, "")
    }

    func testEmptyConfirmedWithNonEmptyPastedIsDivergence() {
        // The committed transcript shrinking below what we've pasted
        // means Whisper has retracted a chunk. Treat as divergence.
        let result = TranscriptDelta.compute(
            confirmed: "",
            alreadyPasted: "hello"
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - Happy path

    func testPrefixMatchReturnsTail() {
        let result = TranscriptDelta.compute(
            confirmed: "hello world",
            alreadyPasted: "hello "
        )
        XCTAssertEqual(result, "world")
    }

    func testExactMatchReturnsEmpty() {
        let result = TranscriptDelta.compute(
            confirmed: "hello world",
            alreadyPasted: "hello world"
        )
        XCTAssertEqual(result, "")
    }

    func testSingleCharacterGrowth() {
        let result = TranscriptDelta.compute(
            confirmed: "a",
            alreadyPasted: ""
        )
        XCTAssertEqual(result, "a")
    }

    func testMultipleCommitsAppend() {
        // Simulate the progressive dictation flow.
        var pasted = ""
        pasted += TranscriptDelta.compute(
            confirmed: "The quick brown",
            alreadyPasted: pasted
        )
        XCTAssertEqual(pasted, "The quick brown")

        pasted += TranscriptDelta.compute(
            confirmed: "The quick brown fox jumps",
            alreadyPasted: pasted
        )
        XCTAssertEqual(pasted, "The quick brown fox jumps")

        pasted += TranscriptDelta.compute(
            confirmed: "The quick brown fox jumps over the lazy dog.",
            alreadyPasted: pasted
        )
        XCTAssertEqual(pasted, "The quick brown fox jumps over the lazy dog.")
    }

    // MARK: - Divergence

    func testWordRewriteIsTreatedAsDivergence() {
        // Whisper rewrites "write" → "right" in a past commit.
        // alreadyPasted is no longer a prefix of confirmed.
        let result = TranscriptDelta.compute(
            confirmed: "you're right about it",
            alreadyPasted: "you're write about"
        )
        XCTAssertEqual(result, "", "Divergence must return empty to avoid double-paste.")
    }

    func testPunctuationChangeIsDivergence() {
        // "hello world" → "hello, world" — the comma in position 5
        // means the pasted text is no longer a prefix.
        let result = TranscriptDelta.compute(
            confirmed: "hello, world!",
            alreadyPasted: "hello world"
        )
        XCTAssertEqual(result, "")
    }

    func testCaseChangeIsDivergence() {
        // Case matters for prefix matching — "hello" ≠ "Hello".
        let result = TranscriptDelta.compute(
            confirmed: "Hello world",
            alreadyPasted: "hello"
        )
        XCTAssertEqual(result, "")
    }

    func testSuffixOnlyGrowthIsDivergence() {
        // Edge case: alreadyPasted contains something that isn't
        // anywhere in confirmed. Divergence.
        let result = TranscriptDelta.compute(
            confirmed: "brand new transcript",
            alreadyPasted: "older content"
        )
        XCTAssertEqual(result, "")
    }

    // MARK: - Unicode

    func testEmojiGrowthReturnsEmojiTail() {
        let result = TranscriptDelta.compute(
            confirmed: "party 🎉 time",
            alreadyPasted: "party "
        )
        XCTAssertEqual(result, "🎉 time")
    }

    func testMultibyteCharacterPrefix() {
        let result = TranscriptDelta.compute(
            confirmed: "café open",
            alreadyPasted: "café "
        )
        XCTAssertEqual(result, "open")
    }
}
