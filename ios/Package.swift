// swift-tools-version: 6.2
import PackageDescription

// SentencePieceC XCFramework path.
// Build it first: ./scripts/build-sentencepiece-ios.sh
// The .xcframework directory must exist before Swift Package Manager resolves
// this package. If it does not exist yet (fresh checkout), the build will fail
// with "binary target path does not exist" — run the build script first.
let sentencePieceFrameworkPath = "Frameworks/sentencepiece-ios.xcframework"

let package = Package(
    name: "nobordershealthcare",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "nobordershealthcare", targets: ["nobordershealthcare"]),
        .library(name: "EmergencyWidget", targets: ["EmergencyWidget"]),
    ],
    targets: [
        .target(
            name: "SHA3Kit",
            path: "Sources/SHA3Kit"
        ),
        // KyberKit: local interface stubs for Kyber-1024 (ML-KEM-1024).
        // Replace the fatalError bodies with swift-oqs (liboqs Swift bindings)
        // once the SPM package is available in the build environment.
        .target(
            name: "KyberKit",
            path: "Sources/KyberKit"
        ),
        // SentencePieceC: C bridge to the SentencePiece tokenizer library.
        // Exposes spm_load / spm_encode / spm_decode / spm_free / spm_bos_id / spm_eos_id.
        // Build with: ./scripts/build-sentencepiece-ios.sh
        .binaryTarget(
            name: "SentencePieceC",
            path: sentencePieceFrameworkPath
        ),
        .target(
            name: "nobordershealthcare",
            dependencies: ["SHA3Kit", "KyberKit", "SentencePieceC"],
            path: "Sources/nobordershealthcare",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "EmergencyWidget",
            dependencies: ["SHA3Kit"],
            path: "Sources/EmergencyWidget",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
