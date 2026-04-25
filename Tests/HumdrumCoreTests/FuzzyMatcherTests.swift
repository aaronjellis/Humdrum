import XCTest
@testable import HumdrumCore

/// Tests the three fuzzy-match tiers used by the sidebar session search:
/// substring, subsequence, and typo-tolerance. The ranking invariants
/// matter more than the absolute numbers — the exact scores can shift
/// as the weights are tuned, but the relative order for common inputs
/// (substring beats subsequence beats typo) must hold.
final class FuzzyMatcherTests: XCTestCase {

    // MARK: - Basic matching behavior

    func testEmptyQueryReturnsZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", in: "budget review"), 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", in: "budget review"))
    }

    func testSubstringMatches() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "budget", in: "q2 budget review"))
    }

    func testSubsequenceMatches() {
        // "bgt" appears as a subsequence in "budget".
        XCTAssertNotNil(FuzzyMatcher.score(query: "bgt", in: "q2 budget review"))
    }

    func testTypoWithinEditDistance() {
        // One transposition: "bduget" → "budget".
        XCTAssertNotNil(FuzzyMatcher.score(query: "bduget", in: "q2 budget review"))
    }

    func testTypoBeyondEditDistanceRejected() {
        // Too many edits for a short token — should reject rather than
        // match everything that remotely resembles the query.
        XCTAssertNil(FuzzyMatcher.score(query: "zzzzz", in: "q2 budget review"))
    }

    // MARK: - Ranking invariants

    func testSubstringScoresHigherThanSubsequence() {
        let substring = FuzzyMatcher.score(query: "budget", in: "budget review")!
        let subsequence = FuzzyMatcher.score(query: "bgt", in: "budget review")!
        XCTAssertGreaterThan(substring, subsequence,
                             "Exact substring matches must rank above subsequence matches")
    }

    func testSubsequenceScoresHigherThanTypo() {
        let subsequence = FuzzyMatcher.score(query: "bgt", in: "budget review")!
        let typo = FuzzyMatcher.score(query: "bduget", in: "budget review")!
        XCTAssertGreaterThan(subsequence, typo,
                             "Subsequence matches must rank above typo-tolerance matches")
    }

    func testPrefixMatchScoresHighestOfSubstrings() {
        let prefix   = FuzzyMatcher.score(query: "budget", in: "budget review")!
        let wordBdy  = FuzzyMatcher.score(query: "review", in: "budget review")!
        let midWord  = FuzzyMatcher.score(query: "udg",    in: "budget review")!
        XCTAssertGreaterThan(prefix, wordBdy)
        XCTAssertGreaterThan(wordBdy, midWord)
    }

    // MARK: - Multi-token queries

    func testMultiTokenOrderIndependent() {
        // Both orderings of the same two tokens should match.
        let a = FuzzyMatcher.score(query: "budget review", in: "q2 budget review")
        let b = FuzzyMatcher.score(query: "review budget", in: "q2 budget review")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
    }

    func testMultiTokenAllMustHit() {
        // "hiring" isn't in the candidate, so the whole query fails
        // even though "budget" is clearly there.
        XCTAssertNil(FuzzyMatcher.score(query: "budget hiring", in: "q2 budget review"))
    }

    // MARK: - Case insensitivity contract
    //
    // The matcher expects lowercased inputs. Verify that the caller's
    // contract holds — an uppercase candidate won't match a lowercase
    // query. This keeps the performance story honest (no hidden
    // lowercasing per-candidate on the hot path).

    func testMatcherIsCaseSensitiveByContract() {
        XCTAssertNil(FuzzyMatcher.score(query: "budget", in: "BUDGET REVIEW"),
                     "Caller is responsible for lowercasing — matcher must not do it internally")
    }
}
