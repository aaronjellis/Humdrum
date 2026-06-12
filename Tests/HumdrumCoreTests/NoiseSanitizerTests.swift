import XCTest
@testable import HumdrumCore

/// Tests for the post-decode hallucination filter. The two invariants
/// worth protecting:
///   1. When `level == .off`, sanitize is a passthrough (never drops).
///   2. When `level != .off`, only *exact whole-string* matches get
///      dropped — substrings inside a real sentence must survive.
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

    // MARK: - Inline non-speech annotation stripping

    func testEmbeddedSquareBracketTagStripped() {
        // Whisper's bracketed sound tags get pulled out even when
        // they're embedded in real speech — this is the dictation
        // user's complaint ("[BACKGROUND NOISE] leaks into my text").
        let result = NoiseSanitizer.sanitize(
            "Intro [Music] then the interview",
            level: .normal
        )
        XCTAssertEqual(result, "Intro then the interview")
    }

    func testBackgroundNoiseTagStrippedInline() {
        let result = NoiseSanitizer.sanitize(
            "Let's get started [BACKGROUND NOISE] with the agenda.",
            level: .normal
        )
        XCTAssertEqual(result, "Let's get started with the agenda.")
    }

    func testBlankAudioTagStripped() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("[BLANK_AUDIO]", level: .normal),
            ""
        )
    }

    func testLeadingAnnotationStrippedAndPunctuationTidied() {
        // The space the stripped tag leaves behind shouldn't strand a
        // gap before the period.
        let result = NoiseSanitizer.sanitize(
            "The meeting is over [coughing].",
            level: .normal
        )
        XCTAssertEqual(result, "The meeting is over.")
    }

    func testMusicNoteSpanStripped() {
        let result = NoiseSanitizer.sanitize(
            "Welcome back ♪ upbeat music ♪ to the show",
            level: .normal
        )
        XCTAssertEqual(result, "Welcome back to the show")
    }

    func testDescriptorParentheticalStripped() {
        let result = NoiseSanitizer.sanitize(
            "So anyway (laughter) where were we",
            level: .normal
        )
        XCTAssertEqual(result, "So anyway where were we")
    }

    func testGenuineParentheticalAsideSurvives() {
        // A real dictated aside is NOT a sound descriptor and must
        // survive — we only strip parentheticals that read as Whisper
        // annotations.
        let result = NoiseSanitizer.sanitize(
            "Email me (I'll send the deck tomorrow) when you can",
            level: .normal
        )
        XCTAssertEqual(
            result,
            "Email me (I'll send the deck tomorrow) when you can"
        )
    }

    func testOffLevelPreservesInlineAnnotations() {
        // .off is a strict passthrough — annotations and all.
        XCTAssertEqual(
            NoiseSanitizer.sanitize("Hello [BACKGROUND NOISE] world", level: .off),
            "Hello [BACKGROUND NOISE] world"
        )
    }

    func testStringThatIsEntirelyAnnotationsCollapsesToEmpty() {
        XCTAssertEqual(
            NoiseSanitizer.sanitize("[NOISE] (coughing) ♪", level: .normal),
            ""
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
