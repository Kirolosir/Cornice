// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cornice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CorniceKit", targets: ["CorniceKit"]),
        .executable(name: "cornice", targets: ["CorniceApp"]),
    ],
    targets: [
        .target(
            name: "CorniceKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CorniceApp",
            dependencies: ["CorniceKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CorniceKitTests",
            dependencies: ["CorniceKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
