import XCTest
@testable import HumdrumCore

/// Tests for the post-decode hallucination filter. The invariants
/// worth protecting:
///   1. When `level == .off`, sanitize is a passthrough (never drops).
///   2. When `level != .off`, whole-string hallucination phrases drop,
///      and non-speech annotation tags ([BLANK_AUDIO], [Music],
///      (laughing), ♪) are stripped wherever they appear — but real
///      spoken words must always survive, including phrases that merely
///      *contain* a hallucination phrase as a substring.
final class NoiseSanitizerTests: XCTestCase {

    // MARK: - Pass-through cases

    func testNormalSentenceAlwaysSurvives() {
        for level in NoiseFilterLevel.allCases {
            let result = NoiseSanitizer.sanitize(
                "On Monday we reviewed the launch plan.",
                level: level
            )
            XCTAssertEqual(
                result,
                "On Monday we reviewed the launch plan.",
                "Sanitize dropped a real sentence at level \(level)."
            )
        }
    }

    func testWhitespaceOnlyReturnsEmpty() {
        for level in NoiseFilterLevel.allCases {
            XCTAssertEqual(NoiseSanitizer.sanitize("   \n\t  ", level: level), "")
        }
    }

    func testNilReturnsEmpty() {
        for level in NoiseFilterLevel.allCases {
            XCTAssertEqual(NoiseSanitizer.sanitize(nil, level: level), "")
        }
    }

    func testTrimsSurroundingWhitespace() {
        let result = NoiseSanitizer.sanitize("  hello  ", level: .normal)
        XCTAssertEqual(result, "hello")
    }

    // MARK: - Level .off is a passthrough

    func testOffLevelPreservesKnownHallucinations() {
        // The whole point of .off is that the user sees exactly what
        // Whisper emitted, music tags and all.
        let result = NoiseSanitizer.sanitize("Thanks for watching.", level: .off)
        XCTAssertEqual(result, "Thanks for watching.")
    }

    func testOffLevelPreservesMusicTag() {
        XCTAssertEqual(NoiseSanitizer.sanitize("[Music]", level: .off), "[Music]")
    }

    // MARK: - Known hallucinations drop at non-off levels

    func testThanksForWatchingDrops() {
        for level in [NoiseFilterLevel.light, .normal, .strict] {
            XCTAssertEqual(
                NoiseSanitizer.sanitize("Thanks for watching.", level: level),
                "",
                "Hallucination should drop at level \(level)."
            )
        }
    }

    func testThankYouForWatchingDrops() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("thank you for watching!", level: .normal),
            ""
        )
    }

    func testPleaseSubscribeDrops() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("Please subscribe.", level: .normal),
            ""
        )
    }

    func testAmaraSubtitleDrops() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize(
                "Subtitles by the Amara.org community",
                level: .normal
            ),
            ""
        )
    }

    func testMusicTagDrops() {
        XCTAssertEqual(NoiseSanitizer.sanitize("[Music]", level: .normal), "")
        XCTAssertEqual(NoiseSanitizer.sanitize("(music)", level: .normal), "")
        XCTAssertEqual(NoiseSanitizer.sanitize("♪", level: .normal), "")
    }

    func testBareYouDrops() {
        // Whisper loves to emit a lone "you" for dead air. Not the
        // user's intent.
        XCTAssertEqual(NoiseSanitizer.sanitize("you", level: .normal), "")
    }

    func testBarePeriodDrops() {
        XCTAssertEqual(NoiseSanitizer.sanitize(".", level: .normal), "")
    }

    func testCaseInsensitiveMatching() {
        // Matching lowercases the trimmed input before comparing.
        XCTAssertEqual(
            NoiseSanitizer.sanitize("THANKS FOR WATCHING.", level: .normal),
            ""
        )
    }

    // MARK: - Conservatism (substring survival)

    func testHallucinationAsSubstringInRealSentenceSurvives() {
        // This is the single most important guard — "thanks." as a
        // word inside a real utterance should NOT be dropped.
        let result = NoiseSanitizer.sanitize(
            "She said thanks. We moved on.",
            level: .normal
        )
        XCTAssertEqual(result, "She said thanks. We moved on.")
    }

    func testPartialThanksForWatchingSurvives() {
        // Make sure we only match the *whole* trimmed string.
        let result = NoiseSanitizer.sanitize(
            "Thanks for watching the demo yesterday.",
            level: .normal
        )
        XCTAssertEqual(result, "Thanks for watching the demo yesterday.")
    }

    // MARK: - Annotation tags strip anywhere (non-off levels)

    func testEmbeddedMusicTagStripped() {
        let result = NoiseSanitizer.sanitize(
            "Intro [Music] then the interview",
            level: .normal
        )
        XCTAssertEqual(result, "Intro then the interview")
    }

    func testBlankAudioTagDrops() {
        XCTAssertEqual(NoiseSanitizer.sanitize("[BLANK_AUDIO]", level: .normal), "")
        XCTAssertEqual(NoiseSanitizer.sanitize("[BLANK AUDIO]", level: .normal), "")
        XCTAssertEqual(NoiseSanitizer.sanitize("[ Silence ]", level: .normal), "")
    }

    func testBlankAudioTagDropsAtAllNonOffLevels() {
        for level in [NoiseFilterLevel.light, .normal, .strict] {
            XCTAssertEqual(
                NoiseSanitizer.sanitize("[BLANK_AUDIO]", level: level),
                "",
                "Annotation tag should drop at level \(level)."
            )
        }
    }

    func testRepeatedTagsDropToEmpty() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("[BLANK_AUDIO] [BLANK_AUDIO] [BLANK_AUDIO]", level: .normal),
            ""
        )
    }

    func testBracketTagMidSentenceStripped() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("we need the report [inaudible] by Friday", level: .normal),
            "we need the report by Friday"
        )
    }

    func testTrailingBlankAudioStripped() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("send it to the whole team [BLANK_AUDIO]", level: .normal),
            "send it to the whole team"
        )
    }

    func testParenthesizedNoiseAnnotationStripped() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("(laughing) okay so next item", level: .normal),
            "okay so next item"
        )
        XCTAssertEqual(
            NoiseSanitizer.sanitize("(clears throat) let's begin", level: .normal),
            "let's begin"
        )
    }

    func testParenthesizedRealContentSurvives() {
        // Parens only strip when the content is a known noise annotation —
        // arbitrary parenthesized words are kept.
        let text = "the budget (see the attached doc) is final"
        XCTAssertEqual(NoiseSanitizer.sanitize(text, level: .normal), text)
    }

    func testParenAnnotationWithInteriorWhitespaceStripped() {
        // Whisper can wrap annotation words across whitespace other than
        // a single space — normalization must treat all whitespace alike.
        XCTAssertEqual(
            NoiseSanitizer.sanitize("(clears\nthroat) let's begin", level: .normal),
            "let's begin"
        )
        XCTAssertEqual(
            NoiseSanitizer.sanitize("(clears\tthroat) let's begin", level: .normal),
            "let's begin"
        )
    }

    func testEmptyParensStripped() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("text ( ) more", level: .normal),
            "text more"
        )
        XCTAssertEqual(
            NoiseSanitizer.sanitize("text () more", level: .normal),
            "text more"
        )
    }

    func testMusicNoteRunStripped() {
        XCTAssertEqual(NoiseSanitizer.sanitize("♪♪♪", level: .normal), "")
        XCTAssertEqual(NoiseSanitizer.sanitize("la la la ♪♪", level: .normal), "la la la")
    }

    func testAnnotationWrappedBannedPhraseDrops() {
        // Deliberate behavior: after tags strip, the remainder is
        // re-checked against the banned list, so a hallucinated phrase
        // decorated with tags ("♪ thanks for watching ♪") drops
        // entirely — both parts are hallucinations.
        XCTAssertEqual(
            NoiseSanitizer.sanitize("♪ Thanks for watching. ♪", level: .normal),
            ""
        )
        XCTAssertEqual(
            NoiseSanitizer.sanitize("[Music] Thank you.", level: .normal),
            ""
        )
    }

    func testOffLevelPreservesBlankAudioTag() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("[BLANK_AUDIO]", level: .off),
            "[BLANK_AUDIO]"
        )
        XCTAssertEqual(
            NoiseSanitizer.sanitize("Intro [Music] outro", level: .off),
            "Intro [Music] outro"
        )
    }

    // MARK: - List hygiene

    func testBannedPhraseListNonEmpty() {
        XCTAssertGreaterThan(NoiseSanitizer.bannedExactPhrases.count, 5)
    }

    func testBannedPhrasesAreAllLowercase() {
        // Matching lowercases the input, so the list must be lowercase
        // too or entries silently stop matching.
        for phrase in NoiseSanitizer.bannedExactPhrases {
            XCTAssertEqual(
                phrase,
                phrase.lowercased(),
                "\"\(phrase)\" has uppercase characters — will never match."
            )
        }
    }
}
