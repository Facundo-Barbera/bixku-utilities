// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BixkuLLM",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BixkuLLM", targets: ["BixkuLLM"]),
    ],
    targets: [
        .target(name: "BixkuLLM"),
        .testTarget(name: "BixkuLLMTests", dependencies: ["BixkuLLM"]),
    ]
)
