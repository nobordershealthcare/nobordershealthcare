// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "nobordershealthcare",
    platforms: [.iOS(.v26)],
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
        .target(
            name: "nobordershealthcare",
            dependencies: ["SHA3Kit", "KyberKit"],
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
