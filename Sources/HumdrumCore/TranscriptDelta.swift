import Foundation

/// Computes the "what should I paste next?" delta between the current
/// committed transcript and what we've already inserted into the
/// focused field.
///
/// Whisper can rewrite older chunks when a later decode improves
/// context (e.g. "write" → "right"). If that happens, the committed
/// transcript no longer starts with what we've already pasted, and
/// continuing to emit the tail would produce wrong-looking text. In
/// that case we return an empty delta and wait for the next commit:
/// re-convergence in subsequent decodes is the common outcome, and
/// the user would much rather see a brief stall than dictated text
/// that slowly drifts out of sync with what they just said.
public enum TranscriptDelta {

    /// Return the suffix of `confirmed` that hasn't been pasted yet.
    ///
    ///   • `confirmed.hasPrefix(alreadyPasted)` → the tail that follows.
    ///   • divergence → `""` (caller should do nothing this tick).
    ///   • `confirmed == alreadyPasted` → `""` (nothing new).
    ///   • `alreadyPasted.isEmpty` → full `confirmed`.
    public static func compute(
        confirmed: String,
        alreadyPasted: String
    ) -> String {
        if alreadyPasted.isEmpty { return confirmed }
        guard confirmed.hasPrefix(alreadyPasted) else { return "" }
        return String(confirmed.dropFirst(alreadyPasted.count))
    }
}
