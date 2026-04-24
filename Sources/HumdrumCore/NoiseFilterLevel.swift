import Foundation

/// How aggressively to drop Whisper output that doesn't look like speech.
///
/// Each level is a bundle of three knobs that Whisper applies during
/// decode (`noSpeechThreshold`, `compressionRatioThreshold`,
/// `logProbThreshold`) plus a pre-decode RMS floor that gates whether
/// we even call the model on a window of audio.
///
/// Lifted into HumdrumCore so the thresholds can be snapshot-tested —
/// a Whisper upgrade could silently change hallucination behavior, and
/// regressions here are the kind of thing that only show up when a user
/// complains their transcripts are full of "Thanks for watching."
public enum NoiseFilterLevel: String, CaseIterable, Identifiable, Sendable {
    case off, light, normal, strict
    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .off:    return "Off"
        case .light:  return "Light"
        case .normal: return "Normal"
        case .strict: return "Strict"
        }
    }

    public var description: String {
        switch self {
        case .off:
            return "Transcribe everything Whisper outputs, including music tags, typing, coughs, and occasional \"Thanks for watching\" hallucinations during silence."
        case .light:
            return "Skip dead silence only. Most borderline audio (typing, HVAC, paper shuffling) still shows up as text."
        case .normal:
            return "Skip silence and suppress Whisper's common hallucinations during quiet stretches. Good default for meetings."
        case .strict:
            return "Aggressively drop anything that doesn't look like clear speech. May cut quiet voices — use only if background noise is severe."
        }
    }

    /// Minimum RMS for a window to even be sent to Whisper.
    public var rmsFloor: Float {
        switch self {
        case .off:    return 0
        case .light:  return 0.002
        case .normal: return 0.004
        case .strict: return 0.008
        }
    }

    public var noSpeechThreshold: Float? {
        switch self {
        case .off:    return nil
        case .light:  return 0.6
        case .normal: return 0.55
        case .strict: return 0.4
        }
    }

    public var compressionRatioThreshold: Float? {
        switch self {
        case .off:    return nil
        case .light:  return 2.8
        case .normal: return 2.4
        case .strict: return 2.0
        }
    }

    public var logProbThreshold: Float? {
        switch self {
        case .off:    return nil
        case .light:  return -1.5
        case .normal: return -1.0
        case .strict: return -0.6
        }
    }
}
