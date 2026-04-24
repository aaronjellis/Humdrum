import XCTest
@testable import HumdrumCore

/// Tests for the UTF-16 chunker used by `PasteHelper.insertViaKeystrokes`.
///
/// The surrogate-pair safety property is the one that matters most in
/// practice — without it, an emoji straddling a 20-unit boundary renders
/// as a replacement glyph in some target apps. The chunk-size invariant
/// comes second: CGEvent's unicode string buffer is known to drop
/// characters past ~20 per event in some Chromium-based renderers.
final class TextChunkerTests: XCTestCase {

    // MARK: - Boundary conditions

    func testEmptyStringProducesNoChunks() {
        XCTAssertEqual(TextChunker.utf16Chunks(for: ""), [])
    }

    func testShortStringFitsInOneChunk() {
        let chunks = TextChunker.utf16Chunks(for: "hello", chunkSize: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], Array("hello".utf16))
    }

    func testExactChunkSizeProducesOneChunk() {
        // 20 ASCII chars → exactly 20 UTF-16 units → one chunk.
        let text = String(repeating: "a", count: 20)
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 20)
    }

    func testOverSizedAsciiSplitsIntoTwoChunks() {
        let text = String(repeating: "a", count: 21)
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 20)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 20)
        XCTAssertEqual(chunks[1].count, 1)
    }

    func testReassembledChunksMatchOriginal() {
        let text = "The quick brown fox jumps over the lazy dog."
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 7)
        let flattened: [UInt16] = chunks.flatMap { $0 }
        XCTAssertEqual(flattened, Array(text.utf16))
    }

    // MARK: - Chunk-size invariant

    func testEveryChunkWithinSizeLimit() {
        let text = String(repeating: "abcdefghij", count: 10) // 100 chars
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 20)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 20)
        }
        XCTAssertGreaterThan(chunks.count, 1)
    }

    // MARK: - Surrogate pair safety

    func testEmojiNeverSplitAcrossChunks() {
        // 🎉 = U+1F389 = two UTF-16 units (D83C DF89).
        // Construct a string where the party popper sits exactly at the
        // 20-unit boundary: 19 `a`s + 🎉 + filler. The high surrogate
        // lands at index 19 with chunkSize 20, which is the dangerous
        // case — naive chunking would cut between D83C and DF89.
        let prefix = String(repeating: "a", count: 19)
        let text = prefix + "🎉" + String(repeating: "b", count: 10)
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 20)

        // No chunk should start with a *low* surrogate (DC00-DFFF) —
        // that would mean the matching high surrogate got stranded on
        // the preceding chunk.
        for chunk in chunks {
            if let first = chunk.first {
                XCTAssertFalse(
                    (0xDC00...0xDFFF).contains(first),
                    "Chunk begins with a lone low surrogate — surrogate pair was split."
                )
            }
            if let last = chunk.last {
                XCTAssertFalse(
                    (0xD800...0xDBFF).contains(last),
                    "Chunk ends with a lone high surrogate — surrogate pair was split."
                )
            }
        }

        // Sanity: reassembled chunks still reproduce the original.
        let flattened: [UInt16] = chunks.flatMap { $0 }
        XCTAssertEqual(flattened, Array(text.utf16))
    }

    func testEmojiOnlyStringProducesValidChunks() {
        // 10 party poppers = 20 UTF-16 units → must fit in one chunk.
        let text = String(repeating: "🎉", count: 10)
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 20)
    }

    func testManyEmojisSplitOnPairBoundaries() {
        // 15 emojis = 30 UTF-16 units. chunkSize 20 → chunks must end
        // on a pair boundary, so they split 20/10 or 18/12 but never
        // 19/11 (which would split a pair).
        let text = String(repeating: "🎉", count: 15)
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 20)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        for chunk in chunks {
            XCTAssertEqual(
                chunk.count % 2,
                0,
                "All-emoji chunk should have even length — pair was split."
            )
        }
    }

    // MARK: - Defensive

    func testZeroChunkSizeFallsBackToSingleChunk() {
        // Programmer error — don't crash, just ship the text.
        let text = "hello world"
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: 0)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], Array(text.utf16))
    }

    func testNegativeChunkSizeFallsBackToSingleChunk() {
        let text = "hello world"
        let chunks = TextChunker.utf16Chunks(for: text, chunkSize: -5)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], Array(text.utf16))
    }
}
