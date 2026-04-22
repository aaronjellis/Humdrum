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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.4.0")
    ],
    targets: [
        .executableTarget(
            name: "Humdrum",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Humdrum"
        )
    ]
)
