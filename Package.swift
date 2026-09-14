// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CGLauncher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CGLauncher", targets: ["CGLauncher"])],
    targets: [
        .target(name: "CGLauncherCore"),
        .executableTarget(name: "CGLauncher", dependencies: ["CGLauncherCore"]),
        .testTarget(name: "CGLauncherCoreTests", dependencies: ["CGLauncherCore"])
    ],
    swiftLanguageModes: [.v5]
)
