// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Uncommitted",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "uncommitted", targets: ["Uncommitted"]),
        .executable(name: "UncommittedTests", targets: ["UncommittedTests"]),
    ],
    targets: [
        // Model, services, stores. Everything testable lives here.
        .target(
            name: "UncommittedCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Thin SwiftUI + AppKit shell that depends on the Core library.
        .executableTarget(
            name: "Uncommitted",
            dependencies: ["UncommittedCore"],
            resources: [
                .copy("Resources/icon-glyph.svg"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Plain executable test runner. XCTest and swift-testing are both
        // unavailable on a Command Line Tools-only toolchain, so we expose
        // the tests via `swift run UncommittedTests` — zero dependencies on
        // external test frameworks.
        .executableTarget(
            name: "UncommittedTests",
            dependencies: ["UncommittedCore"],
            path: "Tests/UncommittedTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
