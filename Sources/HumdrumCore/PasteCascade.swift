import Foundation

/// Outcome of a paste attempt, surfaced to the dictation coordinator.
/// `.inserted` means one of the cascade stages reported it succeeded
/// (clipboard+⌘V or keystroke synthesis). `.failed` means every stage
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
/// The design is deliberately a two-stage cascade, matching how the
/// leading macOS dictation apps do it:
///   • Superwhisper defaults to clipboard + ⌘V, with keystroke
///     simulation as an experimental opt-in in Advanced Settings.
///   • Wispr Flow uses clipboard + ⌘V with a ~500 ms save/restore cycle;
///     keystroke mode is a per-app advanced override.
///   • Aqua Voice / TypeVox take the same posture.
///
/// Clipboard + ⌘V wins as the primary path because ⌘V is the single,
/// OS-blessed insertion event that every mainstream app (Chrome,
/// Electron, Office, JetBrains, Safari, Notes, Terminal) accepts, while
/// `CGEventKeyboardSetUnicodeString` can be silently filtered by
/// Electron renderers (Claude desktop, Slack, Discord, Teams) and by
/// some hardened web views. Keystroke synthesis is retained as the
/// tail fallback for the handful of cases where ⌘V is unavailable (no
/// CGEvent source) or rebound (vim in a terminal, a few niche security
/// tools).
///
/// We also considered AX `kAXSelectedTextAttribute` writes; they're
/// documented as reporting `.success` while silently dropping on too
/// many target apps (Chromium-family browsers, Electron, Office,
/// JetBrains IDEs) to keep as any stage in the cascade.
public enum PasteDecision: Equatable, Sendable {
    /// Input text was empty — no-op, don't touch anything.
    case empty
    /// Accessibility permission missing — can't synthesize ⌘V or unicode events.
    case noAccessibility
    /// Focused element is a secure/password field. We never dictate into
    /// these: shell commands, 1Password autofill, banking logins, etc.
    /// The right thing is to silently drop the paste and let the user
    /// see the orb countdown so they can retype somewhere safe. Leading
    /// dictation apps (Wispr Flow, Superwhisper) all refuse by policy.
    case refused
    /// Go clipboard → keystroke. Clipboard + ⌘V is tried first because
    /// ⌘V is the single OS-blessed insert event that Electron apps and
    /// hardened web views actually accept; keystroke synthesis is the
    /// tail fallback for the rare cases where ⌘V is unavailable or
    /// rebound.
    case clipboardFirst
}

/// AX roles we consider secure/password fields. Any of these in the
/// focused element short-circuits the cascade to `.refused`. Covers
/// both the stable Apple role (`AXSecureTextField`) and the less
/// common "password-field subrole on a generic text field" pattern,
/// which `PasteHelper.focusedAXRole()` normalizes into this role name.
public let axSecureTextRoles: Set<String> = [
    "AXSecureTextField",
]

/// Abstraction over the two concrete paste strategies — clipboard + ⌘V
/// and keystroke synthesis. The real implementation wraps
/// `NSPasteboard` / `CGEvent.post` in the executable target; tests use
/// an in-memory fake that records call ordering and lets each stage be
/// dialed to succeed or fail independently so every cascade branch is
/// exercisable.
public protocol PasteBackend {
    /// Write `text` to the clipboard and synthesize ⌘V, restoring the
    /// previous clipboard contents afterwards. Returns `false` only if
    /// the event source couldn't be created.
    func insertViaClipboard(_ text: String) -> Bool

    /// Post synthetic keyboard events carrying `text`. Returns `false`
    /// only if the event source couldn't be created.
    func insertViaKeystrokes(_ text: String) -> Bool
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
    /// hooks and for future per-app overrides (e.g. a small set of
    /// bundle IDs that need to route to keystrokes directly because
    /// ⌘V is rebound — vim in a terminal, niche security tools). The
    /// default cascade is clipboard-first for every non-refused paste.
    public static func decide(
        text: String,
        hasAccessibility: Bool,
        bundleID: String?,
        focusedRole: String?
    ) -> PasteDecision {
        _ = bundleID  // reserved for future per-app overrides + logging
        if text.isEmpty { return .empty }
        if !hasAccessibility { return .noAccessibility }

        // Refuse before anything else: if the user is focused in a
        // password field, we don't paste no matter how confidently
        // the app would accept it. Matches the policy every leading
        // dictation app takes.
        if let role = focusedRole, axSecureTextRoles.contains(role) {
            return .refused
        }

        // Everything else routes through the same clipboard → keystroke
        // cascade. No role probing beyond password refusal — ⌘V handles
        // the "is this actually editable?" question at the OS input layer.
        return .clipboardFirst
    }

    /// Run the decided strategy through the given backend. `.clipboardFirst`
    /// tries clipboard + ⌘V first and falls back to keystroke synthesis
    /// if the clipboard path can't construct a CGEvent source.
    @discardableResult
    public static func execute(
        text: String,
        decision: PasteDecision,
        backend: PasteBackend
    ) -> PasteResult {
        switch decision {
        case .empty, .noAccessibility, .refused:
            return .failed

        case .clipboardFirst:
            if backend.insertViaClipboard(text)  { return .inserted }
            if backend.insertViaKeystrokes(text) { return .inserted }
            return .failed
        }
    }
}
