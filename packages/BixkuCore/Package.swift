// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BixkuCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BixkuCore", targets: ["BixkuCore"]),
    ],
    targets: [
        .target(name: "BixkuCore"),
        .testTarget(name: "BixkuCoreTests", dependencies: ["BixkuCore"]),
    ]
)
