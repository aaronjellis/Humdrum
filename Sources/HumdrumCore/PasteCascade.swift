import Foundation

/// Outcome of a paste attempt, surfaced to the dictation coordinator.
/// `.inserted` means one of the cascade stages reported it succeeded
/// (keystroke synthesis or clipboard+⌘V). `.failed` means every stage
/// either short-circuited (empty text, no Accessibility, password
/// field refusal) or fell through — the coordinator uses this to
/// avoid advancing `pastedText`, so the chunk can be retried in the
/// next tick.
public enum PasteResult: Equatable, Sendable {
    case inserted
    case failed
}

/// The strategy picked for a single paste call. Produced by
/// `PasteCascade.decide` as a pure function of the inputs; consumed by
/// `PasteCascade.execute` which calls into the concrete `PasteBackend`.
///
/// Keeping this explicit (as opposed to hiding it inside `execute`)
/// means the decision can be logged, asserted in tests, and reasoned
/// about without needing a full cascade run.
///
/// The design is deliberately a two-stage cascade. Research into leading
/// macOS dictation apps (Superwhisper, Wispr Flow, TypeVox, Talon, Aqua
/// Voice) and reproducible failure reports against the AX path in
/// Chromium-family browsers, Electron apps, Microsoft Office, and
/// JetBrains IDEs converge on the same conclusion: the AX
/// "set `kAXSelectedTextAttribute`" path reports `.success` while
/// silently dropping the write often enough that it's not worth
/// keeping as a primary strategy. Going keystroke-first universally is
/// simpler, more reliable, and avoids an entire class of verification
/// gymnastics.
public enum PasteDecision: Equatable, Sendable {
    /// Input text was empty — no-op, don't touch anything.
    case empty
    /// Accessibility permission missing — can't synthesize keystrokes.
    case noAccessibility
    /// Focused element is a secure/password field. We never dictate into
    /// these: shell commands, 1Password autofill, banking logins, etc.
    /// The right thing is to silently drop the paste and let the user
    /// see the orb countdown so they can retype somewhere safe. Leading
    /// dictation apps (Wispr Flow, Superwhisper) all refuse by policy.
    case refused
    /// Go keystroke → clipboard. The one and only active path for every
    /// non-refused, non-short-circuit paste. Keystroke synthesis is the
    /// same mechanism the OS uses for native text substitution, so it
    /// routes through whatever custom input handling the target app
    /// installs (critical for Electron). Clipboard is the tail fallback
    /// for the handful of apps that filter synthetic unicode events.
    case keystrokeFirst
}

/// AX roles we consider secure/password fields. Any of these in the
/// focused element short-circuits the cascade to `.refused`. Covers
/// both the stable Apple role (`AXSecureTextField`) and the less
/// common "password-field subrole on a generic text field" pattern,
/// which `PasteHelper.focusedAXRole()` normalizes into this role name.
public let axSecureTextRoles: Set<String> = [
    "AXSecureTextField",
]

/// Abstraction over the two concrete paste strategies — keystroke
/// synthesis and clipboard + ⌘V. The real implementation wraps
/// `CGEvent.post` / `NSPasteboard` in the executable target; tests
/// use an in-memory fake that records call ordering and lets each
/// stage be dialed to succeed or fail independently so every cascade
/// branch is exercisable.
public protocol PasteBackend {
    /// Post synthetic keyboard events carrying `text`. Returns `false`
    /// only if the event source couldn't be created.
    func insertViaKeystrokes(_ text: String) -> Bool

    /// Write `text` to the clipboard and synthesize ⌘V, restoring the
    /// previous clipboard contents afterwards. Returns `false` only if
    /// the event source couldn't be created.
    func insertViaClipboard(_ text: String) -> Bool
}

/// Pure-logic paste-cascade orchestration. No AppKit, no AX, no
/// CGEvent — everything calls through `PasteBackend`. Tested end-to-end
/// by `HumdrumCoreTests.PasteCascadeTests` with a fake backend.
public enum PasteCascade {

    /// Decide which strategy to attempt, as a pure function of the
    /// inputs. No side effects; same inputs always give the same
    /// decision. Called once per paste attempt from the executable,
    /// which passes in the live accessibility status, frontmost
    /// bundle ID, and the focused element's AX role (if readable).
    ///
    /// `bundleID` is retained in the signature for telemetry/logging
    /// hooks — the decision itself no longer branches on it. With AX
    /// removed as a primary strategy, every app goes through the same
    /// keystroke → clipboard flow; a bundle-ID skip list would have
    /// nothing to do.
    public static func decide(
        text: String,
        hasAccessibility: Bool,
        bundleID: String?,
        focusedRole: String?
    ) -> PasteDecision {
        _ = bundleID  // reserved for future logging
        if text.isEmpty { return .empty }
        if !hasAccessibility { return .noAccessibility }

        // Refuse before anything else: if the user is focused in a
        // password field, we don't paste no matter how confidently
        // the app would accept it. Matches the policy every leading
        // dictation app takes.
        if let role = focusedRole, axSecureTextRoles.contains(role) {
            return .refused
        }

        // Everything else routes through the same keystroke → clipboard
        // cascade. No role probing, no bundle-ID branching — keystroke
        // synthesis is universal and the clipboard is the universal
        // fallback.
        return .keystrokeFirst
    }

    /// Run the decided strategy through the given backend. `.keystrokeFirst`
    /// tries keystroke synthesis first and falls back to clipboard+⌘V
    /// if the keystroke path can't construct a CGEvent source.
    @discardableResult
    public static func execute(
        text: String,
        decision: PasteDecision,
        backend: PasteBackend
    ) -> PasteResult {
        switch decision {
        case .empty, .noAccessibility, .refused:
            return .failed

        case .keystrokeFirst:
            if backend.insertViaKeystrokes(text) { return .inserted }
            if backend.insertViaClipboard(text)  { return .inserted }
            return .failed
        }
    }
}
