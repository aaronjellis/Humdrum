import Foundation

/// How the user activates Mutter dictation.
///
/// The two modes have meaningfully different commit contracts:
///
/// - `toggle`: Tap ⌥Space to start, the engine commits at end-of-
///   utterance (phase 1 of the silence countdown) and keeps listening;
///   tap ⌥Space again or stay silent through both phases to stop. The
///   default — same activation pattern Whisper Flow and Superwhisper
///   use, and what the rest of the orb's animation language was
///   designed around.
///
/// - `pushToTalk`: Hold ⌥Space to listen; release to commit. Release
///   of EITHER ⌥ or Space is the only commit signal — silence
///   detection and phase-1 commits are skipped while held. Better in
///   loud environments where silence-based auto-stop misfires, and for
///   users who'd rather control session length explicitly. The orb
///   still breathes and shows listening dots, but the silence
///   countdown ring is hidden because there is no countdown.
///
/// Pure-logic enum so the value can live in HumdrumCore alongside the
/// other persisted configuration types (NoiseFilterLevel,
/// CommitThresholds). The Humdrum target's PushToTalkMonitor and
/// DictationCoordinator branch on this value to install the right
/// activation surface and to gate the silence-monitor logic.
public enum DictationActivationMode: String, CaseIterable, Codable, Sendable {
    case toggle
    case pushToTalk

    /// Short label for tile-style pickers. Intentionally action-led
    /// rather than mode-named — "Tap to listen" reads better in a UI
    /// than "Toggle".
    public var shortLabel: String {
        switch self {
        case .toggle:     return "Tap to listen"
        case .pushToTalk: return "Press and hold"
        }
    }

    /// One-sentence description suitable for tile subtitle / Settings
    /// footnote. Phrased so the two read as a parallel pair when the
    /// user sees them side-by-side in onboarding.
    public var detail: String {
        switch self {
        case .toggle:
            return "Press once and let it listen, then stop when you stop talking."
        case .pushToTalk:
            return "Hold ⌥Space to dictate. Release when you're done."
        }
    }
}
