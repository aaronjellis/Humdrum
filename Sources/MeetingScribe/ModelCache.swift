import Foundation
import SwiftUI

/// Observable truth about which Whisper model folders are currently
/// cached on disk. Setup window reads this to show per-Quality badges
/// ("Included", "Cached", or "Downloads 145 MB on first use").
///
/// Also tracks whether each cached model came from the app bundle vs
/// from a user-triggered download — this just changes the badge text.
@MainActor
final class ModelCache: ObservableObject {

    @Published private(set) var cachedModels: Set<String> = []
    @Published private(set) var bundledModels: Set<String> = []

    init() {
        refresh()
    }

    /// Rescans disk + bundle. Cheap — pure FileManager.fileExists checks.
    func refresh() {
        cachedModels = Self.discoverCached()
        bundledModels = Self.discoverBundled()
    }

    // MARK: - Query helpers

    func isCached(_ quality: QualityLevel) -> Bool {
        cachedModels.contains(quality.modelId)
    }

    func isBundled(_ quality: QualityLevel) -> Bool {
        bundledModels.contains(quality.modelId)
    }

    // MARK: - Disk probe

    private static func discoverCached() -> Set<String> {
        let fm = FileManager.default
        let folder = BundledModels.whisperKitCacheFolder
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var result: Set<String> = []
        for url in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            // Consider a folder "cached" if it contains at least the three
            // Core ML sub-bundles WhisperKit expects. Avoids treating a
            // half-downloaded folder as ready.
            let name = url.lastPathComponent
            let hasEncoder  = fm.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path)
            let hasDecoder  = fm.fileExists(atPath: url.appendingPathComponent("TextDecoder.mlmodelc").path)
            let hasMel      = fm.fileExists(atPath: url.appendingPathComponent("MelSpectrogram.mlmodelc").path)
            if hasEncoder && hasDecoder && hasMel {
                result.insert(name)
            }
        }
        return result
    }

    private static func discoverBundled() -> Set<String> {
        let fm = FileManager.default
        guard let bundleRoot = Bundle.main.resourceURL?
                .appendingPathComponent("WhisperModels", isDirectory: true),
              fm.fileExists(atPath: bundleRoot.path),
              let entries = try? fm.contentsOfDirectory(
                at: bundleRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
              )
        else { return [] }

        var result: Set<String> = []
        for url in entries {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                result.insert(url.lastPathComponent)
            }
        }
        return result
    }
}
