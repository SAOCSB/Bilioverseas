// swift-tools-version:5.9
// Builds the platform-independent core (networking, BTR acceleration, danmaku parsing,
// SmartSkip, feed filters) as a library so it can be unit-tested with `swift test` on macOS.
// The iOS app target (project.yml) compiles the same sources directly.
import PackageDescription

let package = Package(
    name: "BiliCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "BiliCore", targets: ["BiliCore"]),
    ],
    targets: [
        .target(
            name: "BiliCore",
            path: "BiliOverseas/Core",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "BiliCoreTests",
            dependencies: ["BiliCore"],
            path: "Tests/BiliCoreTests"
        ),
    ]
)
