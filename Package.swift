// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Humdrum",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Humdrum", targets: ["Humdrum"])
    ],
    dependencies: [
        // WhisperKit: Apple-Silicon–optimized, 100% local Whisper transcription (MIT).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // FluidAudio: local speaker diarization (pyannote segmentation + speaker
        // embedding models, compiled to Core ML). Apache-2.0.
        // If this version no longer resolves, check
        // https://github.com/FluidInference/FluidAudio/releases for a current
        // tag and update the constraint below.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.4.0"),
        // Sparkle 2: signed auto-update framework. Config keys live in
        // Info.plist (SUFeedURL, SUPublicEDKey, etc.); SPM just supplies
        // the framework binary that build-app.sh copies into
        // Contents/Frameworks and signs inner-first.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        // Pure-logic module. No Apple framework dependencies and no
        // @MainActor types, so it can be exercised from XCTest without
        // spinning up an app host. Everything exported is `public`.
        .target(
            name: "HumdrumCore",
            path: "Sources/HumdrumCore"
        ),
        .executableTarget(
            name: "Humdrum",
            dependencies: [
                "HumdrumCore",
                .product(name: "WhisperKit",  package: "WhisperKit"),
                .product(name: "FluidAudio",  package: "FluidAudio"),
                .product(name: "Sparkle",     package: "Sparkle")
            ],
            path: "Sources/Humdrum"
        ),
        .testTarget(
            name: "HumdrumCoreTests",
            dependencies: ["HumdrumCore"],
            path: "Tests/HumdrumCoreTests"
        )
    ]
)
