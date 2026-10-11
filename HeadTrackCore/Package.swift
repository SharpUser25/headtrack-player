// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeadTrackCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeadTrackCore", targets: ["HeadTrackCore"]),
    ],
    targets: [
        .target(name: "HeadTrackCore"),
        .testTarget(name: "HeadTrackCoreTests", dependencies: ["HeadTrackCore"]),
    ]
)
