import XCTest
@testable import HumdrumCore

/// Snapshot tests for the Whisper decode thresholds keyed off
/// `NoiseFilterLevel`. These are deliberately rigid — if someone changes
/// a threshold, they should have to explicitly update the test and
/// leave a paper trail. Silent tuning here shows up as "my transcript
/// dropped half my speech" months later when a user complains.
final class NoiseFilterLevelTests: XCTestCase {

    // MARK: - Case coverage

    func testAllCasesPresent() {
        XCTAssertEqual(
            Set(NoiseFilterLevel.allCases),
            Set([.off, .light, .normal, .strict])
        )
    }

    func testRawValuesAreStable() {
        // Persisted to UserDefaults — changing a raw value would
        // silently reset existing users to the default.
        XCTAssertEqual(NoiseFilterLevel.off.rawValue, "off")
        XCTAssertEqual(NoiseFilterLevel.light.rawValue, "light")
        XCTAssertEqual(NoiseFilterLevel.normal.rawValue, "normal")
        XCTAssertEqual(NoiseFilterLevel.strict.rawValue, "strict")
    }

    // MARK: - RMS floor

    func testOffHasNoRMSFloor() {
        XCTAssertEqual(NoiseFilterLevel.off.rmsFloor, 0)
    }

    func testRMSFloorMonotonicallyIncreases() {
        // Higher level = more aggressive = higher floor. A regression
        // where strict is *below* normal would silently let quiet noise
        // through on strict, which defeats the whole feature.
        XCTAssertLessThan(NoiseFilterLevel.off.rmsFloor, NoiseFilterLevel.light.rmsFloor)
        XCTAssertLessThan(NoiseFilterLevel.light.rmsFloor, NoiseFilterLevel.normal.rmsFloor)
        XCTAssertLessThan(NoiseFilterLevel.normal.rmsFloor, NoiseFilterLevel.strict.rmsFloor)
    }

    func testRMSFloorSnapshotValues() {
        XCTAssertEqual(NoiseFilterLevel.light.rmsFloor, 0.002, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.normal.rmsFloor, 0.004, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.strict.rmsFloor, 0.008, accuracy: 1e-6)
    }

    // MARK: - Whisper decode thresholds

    func testOffDisablesAllWhisperThresholds() {
        // Passing nil to WhisperKit means "don't filter" — .off should
        // give a nil for each of the three decode thresholds.
        XCTAssertNil(NoiseFilterLevel.off.noSpeechThreshold)
        XCTAssertNil(NoiseFilterLevel.off.compressionRatioThreshold)
        XCTAssertNil(NoiseFilterLevel.off.logProbThreshold)
    }

    func testNoSpeechThresholdSnapshot() {
        XCTAssertEqual(NoiseFilterLevel.light.noSpeechThreshold ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.normal.noSpeechThreshold ?? 0, 0.55, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.strict.noSpeechThreshold ?? 0, 0.4, accuracy: 1e-6)
    }

    func testCompressionRatioThresholdDecreasesWithStrictness() {
        // Lower compression ratio = fewer tokens accepted. Strict
        // should be the lowest (most aggressive).
        let light = NoiseFilterLevel.light.compressionRatioThreshold ?? 0
        let normal = NoiseFilterLevel.normal.compressionRatioThreshold ?? 0
        let strict = NoiseFilterLevel.strict.compressionRatioThreshold ?? 0
        XCTAssertGreaterThan(light, normal)
        XCTAssertGreaterThan(normal, strict)
    }

    func testCompressionRatioThresholdSnapshot() {
        XCTAssertEqual(NoiseFilterLevel.light.compressionRatioThreshold ?? 0, 2.8, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.normal.compressionRatioThreshold ?? 0, 2.4, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.strict.compressionRatioThreshold ?? 0, 2.0, accuracy: 1e-6)
    }

    func testLogProbThresholdIncreasesWithStrictness() {
        // Higher (less negative) log-prob = we only accept decodes
        // Whisper is more confident in. Strict should be highest.
        let light = NoiseFilterLevel.light.logProbThreshold ?? 0
        let normal = NoiseFilterLevel.normal.logProbThreshold ?? 0
        let strict = NoiseFilterLevel.strict.logProbThreshold ?? 0
        XCTAssertLessThan(light, normal)
        XCTAssertLessThan(normal, strict)
    }

    func testLogProbThresholdSnapshot() {
        XCTAssertEqual(NoiseFilterLevel.light.logProbThreshold ?? 0, -1.5, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.normal.logProbThreshold ?? 0, -1.0, accuracy: 1e-6)
        XCTAssertEqual(NoiseFilterLevel.strict.logProbThreshold ?? 0, -0.6, accuracy: 1e-6)
    }

    // MARK: - Display

    func testShortLabelsNonEmpty() {
        for level in NoiseFilterLevel.allCases {
            XCTAssertFalse(level.shortLabel.isEmpty)
        }
    }

    func testShortLabelsAreUnique() {
        let labels = NoiseFilterLevel.allCases.map(\.shortLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
