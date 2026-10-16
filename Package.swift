// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cornice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CorniceKit", targets: ["CorniceKit"]),
        .executable(name: "cornice", targets: ["CorniceApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CorniceKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CorniceApp",
            dependencies: ["CorniceKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "CorniceKitTests",
            dependencies: ["CorniceKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
