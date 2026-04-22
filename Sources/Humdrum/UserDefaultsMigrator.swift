import Foundation

/// One-shot migration of `UserDefaults` keys from the project's old
/// "MeetingScribe.*" namespace to the new "Humdrum.*" namespace.
///
/// Called from `HumdrumApp.init()` on every launch; the `migrated` flag
/// makes it a no-op after the first successful pass, so the cost on all
/// subsequent launches is a single bool read.
///
/// This exists because the rebrand happened after real preferences had
/// been written (default save folder, auto-save toggle, dictation
/// hotkey / silence timeout). Without migration the user would open
/// Settings after the rename and find everything reset to defaults.
enum UserDefaultsMigrator {

    /// Bumped whenever the migration map below changes so we can re-run
    /// it on upgrade without tripping the "already migrated" guard.
    private static let migrationVersionKey = "Humdrum.migration.version"
    private static let currentVersion = 1

    /// Old-key → new-key pairs. Order doesn't matter; each copy is
    /// independent.
    private static let map: [(old: String, new: String)] = [
        ("MeetingScribe.defaultSaveFolder",        "Humdrum.defaultSaveFolder"),
        ("MeetingScribe.defaultSaveFormat",        "Humdrum.defaultSaveFormat"),
        ("MeetingScribe.autoSaveOnRecordEnd",      "Humdrum.autoSaveOnRecordEnd"),
        ("MeetingScribe.diarization.consentedV1",  "Humdrum.diarization.consentedV1"),
        ("MeetingScribe.dictation.hotkeyEnabled",  "Humdrum.dictation.hotkeyEnabled"),
        ("MeetingScribe.dictation.silenceTimeout", "Humdrum.dictation.silenceTimeout")
    ]

    static func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: migrationVersionKey)
        guard storedVersion < currentVersion else { return }

        for (old, new) in map {
            // Only migrate if we have an old value AND there's no new
            // value already. That way a user who launched a fresh
            // install after the rename doesn't get their new choices
            // clobbered by a stale old value.
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }

        defaults.set(currentVersion, forKey: migrationVersionKey)
    }
}
