import Foundation
import os.log

/// Centralized logging for Humdrum.
///
/// Each subsystem maps to a separate `os.log` category so a developer or
/// curious user running `log show --predicate 'subsystem == "com.aaronellis.humdrum"'`
/// can filter to just the layer they care about.
///
/// **No transcribed text in logs.** Engine, paste, and learning logs may
/// reference token counts, character counts, durations, model IDs, and
/// outcome flags — never the actual content the user spoke or pasted.
/// This is the bright line that lets us surface "Reveal Diagnostic Logs"
/// without leaking what the user said.
///
/// **Phase α (H015 tonight slice):** just the typed `Logger` accessors.
/// Rotating daily file export, OSLogStore querying, and the "Reveal
/// Diagnostic Logs" Settings menu item land in subsequent evenings.
/// Calling these from the start means when file rotation is wired in
/// later, the events are already populated in OSLog ready to be
/// queried — no retroactive instrumentation pass needed.
enum Diagnostics {
    /// Bundle identifier — matches `Info.plist`/Sparkle config so logs
    /// from this app group together in Console.app and `log show`.
    /// Exposed (not `private`) so the Settings → Diagnostics row can
    /// copy this string to the clipboard for the user to paste into
    /// Console.app's filter field.
    static let subsystem = "com.aaronellis.humdrum"

    /// Standalone push-to-talk dictation. Hotkey received, overlay
    /// shown/hidden, paste destination resolution.
    static let dictation = Logger(subsystem: subsystem, category: "dictation")

    /// WhisperKit / Core ML lifecycle: model load, prewarm inference,
    /// finalize timing, transcribe failures.
    static let engine = Logger(subsystem: subsystem, category: "engine")

    /// PasteHelper / PasteCascade: which strategy was chosen for the
    /// frontmost app, whether the post-paste verification matched,
    /// fallback transitions.
    static let paste = Logger(subsystem: subsystem, category: "paste")

    /// macOS permission state changes — Microphone, Accessibility,
    /// Input Monitoring. Logged when probed, when status changes, when
    /// the user is bounced to System Settings.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    /// Learning loop (H009/H010): correction recorded, anchor created,
    /// substitution applied, vocabulary seed injected.
    static let learning = Logger(subsystem: subsystem, category: "learning")

    /// Outbound network — Sparkle update checks, model downloads.
    /// Distinct subsystem so a future "egress audit" panel can show
    /// "the only network calls Humdrum makes are these".
    static let network = Logger(subsystem: subsystem, category: "network")

    /// SwiftUI lifecycle: window opens, sheet transitions, scene phase.
    /// Most useful when reproducing focus / hotkey ordering bugs.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
