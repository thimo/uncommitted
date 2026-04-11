// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Uncommitted",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "uncommitted", targets: ["Uncommitted"]),
    ],
    targets: [
        .executableTarget(
            name: "Uncommitted",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
