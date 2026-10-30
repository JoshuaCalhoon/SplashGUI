// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SplashGUI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SplashGUI",
            path: "Sources/SplashGUI"
        )
    ],
    swiftLanguageModes: [.v5]
)