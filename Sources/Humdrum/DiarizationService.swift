import Foundation
import FluidAudio

/// Wraps FluidAudio's DiarizerManager so the rest of the app doesn't depend
/// on its API shape. This runs batch diarization on the full audio buffer
/// after recording stops — we get accurate, consistent speaker labels at the
/// cost of a short delay on Stop (typically 1–5 s per minute of audio).
///
/// Why not stream? True streaming diarization that re-IDs speakers across
/// chunks is a research problem; running the full pass once at the end gives
/// dramatically better clustering, which is what users actually care about
/// in a transcript.
@MainActor
final class DiarizationService {

    /// A time-ranged label for a stretch of audio.
    struct Segment {
        let start: Float      // seconds from start of audio
        let end: Float
        let rawSpeakerId: String
    }

    private var manager: DiarizerManager?
    private(set) var isReady: Bool = false
    private(set) var lastError: String?

    /// Downloads / compiles the diarization models on first use. Safe to call
    /// repeatedly; becomes a no-op once ready.
    ///
    /// FluidAudio split model loading out of `initialize` in recent versions:
    /// we first materialize a `DiarizerModels` (download + compile if it's
    /// not already cached), then hand it to the manager. `initialize` is
    /// synchronous and takes ownership of the models value.
    func prepareIfNeeded() async throws {
        if isReady { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager(config: .default)
        m.initialize(models: consume models)
        self.manager = m
        self.isReady = true
    }

    /// Runs diarization on `samples` at 16 kHz mono. Returns speaker-tagged
    /// time ranges. FluidAudio's speakerId strings (e.g. "speaker_0") are
    /// returned as-is; caller is responsible for renumbering them to
    /// "Speaker 1" / "Speaker 2" / … in order of first appearance.
    func diarize(samples: [Float], sampleRate: Int = 16_000) async throws -> [Segment] {
        try await prepareIfNeeded()
        guard let manager else { return [] }
        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)
        return result.segments.map { seg in
            Segment(
                start: Float(seg.startTimeSeconds),
                end: Float(seg.endTimeSeconds),
                rawSpeakerId: seg.speakerId
            )
        }
    }

    /// Finds the speaker who spoke the most within [start, end]. Returns
    /// nil if no overlap.
    static func dominantSpeaker(
        for start: Float,
        _ end: Float,
        in segments: [Segment]
    ) -> String? {
        guard start < end else { return nil }
        var perSpeaker: [String: Float] = [:]
        for s in segments {
            let overlap = min(end, s.end) - max(start, s.start)
            if overlap > 0 {
                perSpeaker[s.rawSpeakerId, default: 0] += overlap
            }
        }
        return perSpeaker.max(by: { $0.value < $1.value })?.key
    }
}
