import Foundation

/// If the .app bundle ships with pre-fetched Whisper model folders inside
/// `Contents/Resources/WhisperModels/`, copy each one into WhisperKit's
/// default cache directory on first launch. After that, WhisperKit finds
/// them locally with no network fetch.
///
/// The build script (`build-app.sh`) is responsible for populating
/// Resources/WhisperModels. If it's empty (or git-lfs wasn't available at
/// build time), this is a no-op — the app still works, models just
/// download on first use the usual way.
enum BundledModels {

    /// WhisperKit's default model cache lives under
    /// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`.
    static var whisperKitCacheFolder: URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        return docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// Copies every model folder from `Resources/WhisperModels/` in the
    /// bundle into the cache location, unless it's already there.
    /// Returns the set of model IDs that are now in cache as a result.
    @discardableResult
    static func installIfNeeded() -> Set<String> {
        let fm = FileManager.default
        var installed: Set<String> = []

        guard let bundledRoot = Bundle.main.resourceURL?
                .appendingPathComponent("WhisperModels", isDirectory: true),
              fm.fileExists(atPath: bundledRoot.path) else {
            return installed
        }

        // Ensure the cache folder exists.
        try? fm.createDirectory(
            at: whisperKitCacheFolder,
            withIntermediateDirectories: true
        )

        guard let entries = try? fm.contentsOfDirectory(
            at: bundledRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return installed
        }

        for source in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            let name = source.lastPathComponent
            let dest = whisperKitCacheFolder.appendingPathComponent(name, isDirectory: true)

            if fm.fileExists(atPath: dest.path) {
                installed.insert(name)
                continue
            }

            do {
                try fm.copyItem(at: source, to: dest)
                installed.insert(name)
                NSLog("Installed bundled Whisper model: \(name)")
            } catch {
                NSLog("Failed to install bundled model \(name): \(error)")
            }
        }

        return installed
    }
}
